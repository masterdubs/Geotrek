import json
import logging

from django.conf import settings
from django.db import connection
from django.contrib.gis.geos import Point
from django.db.models.query import QuerySet
from django.utils.translation import ugettext_lazy as _
from django.contrib.gis.geos import LineString

from geotrek.common.utils import sqlfunction, sampling

import pygal
from pygal.style import LightSolarizedStyle



logger = logging.getLogger(__name__)


class TopologyHelper(object):
    @classmethod
    def deserialize(cls, serialized):
        """
        Topologies can be points or lines. Serialized topologies come from Javascript
        module ``topology_helper.js``.

        Example of linear point topology (snapped with path 1245):

            {"lat":5.0, "lng":10.2, "snap":1245}

        Example of linear serialized topology :

        [
            {"offset":0,"positions":{"0":[0,0.3],"1":[0.2,1]},"paths":[1264,1208]},
            {"offset":0,"positions":{"0":[0.2,1],"5":[0,0.2]},"paths":[1208,1263,678,1265,1266,686]}
        ]

        * Each sub-topology represents a way between markers.
        * Start point is first position of sub-topology.
        * End point is last position of sub-topology.
        * All last positions represents intermediary markers.

        Global strategy is :
        * If has lat/lng return point topology
        * Otherwise, create path aggregations from serialized data.
        """
        from .models import Path, Topology, PathAggregation
        from .factories import TopologyFactory

        try:
            return Topology.objects.get(pk=int(serialized))
        except Topology.DoesNotExist:
            raise
        except ValueError:
            pass  # value is not integer, thus should be deserialized

        objdict = serialized
        if isinstance(serialized, basestring):
            try:
                objdict = json.loads(serialized)
            except ValueError as e:
                raise ValueError("Invalid serialization: %s" % e)

        if not isinstance(objdict, (list,)):
            lat = objdict.get('lat')
            lng = objdict.get('lng')
            kind = objdict.get('kind')
            # Point topology ?
            if lat and lng:
                return cls._topologypoint(lng, lat, kind, snap=objdict.get('snap'))
            else:
                objdict = [objdict]

        # Path aggregation, remove all existing
        if len(objdict) == 0:
            raise ValueError("Invalid serialized topology : empty list found")
        kind = objdict[0].get('kind')
        offset = objdict[0].get('offset', 0.0)
        topology = TopologyFactory.create(no_path=True, kind=kind, offset=offset)
        PathAggregation.objects.filter(topo_object=topology).delete()
        try:
            counter = 0
            for j, subtopology in enumerate(objdict):
                last_topo = j == len(objdict) - 1
                positions = subtopology.get('positions', {})
                paths = subtopology['paths']
                # Create path aggregations
                for i, path in enumerate(paths):
                    last_path = i == len(paths) - 1
                    # Javascript hash keys are parsed as a string
                    idx = str(i)
                    start_position, end_position = positions.get(idx, (0.0, 1.0))
                    path = Path.objects.get(pk=path)
                    topology.add_path(path, start=start_position, end=end_position, order=counter, reload=False)
                    if not last_topo and last_path:
                        # Intermediary marker.
                        # make sure pos will be [X, X]
                        # [0, X] or [X, 1] or [X, 0] or [1, X] --> X
                        # [0.0, 0.0] --> 0.0  : marker at beginning of path
                        # [1.0, 1.0] --> 1.0  : marker at end of path
                        pos = -1
                        if start_position == end_position:
                            pos = start_position
                        if start_position == 0.0:
                            pos = end_position
                        elif start_position == 1.0:
                            pos = end_position
                        elif end_position == 0.0:
                            pos = start_position
                        elif end_position == 1.0:
                            pos = start_position
                        elif len(paths) == 1:
                            pos = end_position
                        assert pos >= 0, "Invalid position (%s, %s)." % (start_position, end_position)
                        topology.add_path(path, start=pos, end=pos, order=counter, reload=False)
                    counter += 1
        except (AssertionError, ValueError, KeyError, Path.DoesNotExist) as e:
            raise ValueError("Invalid serialized topology : %s" % e)
        topology.save()
        return topology

    @classmethod
    def _topologypoint(cls, lng, lat, kind=None, snap=None):
        """
        Receives a point (lng, lat) with API_SRID, and returns
        a topology objects with a computed path aggregation.
        """
        from .models import Path, PathAggregation
        from .factories import TopologyFactory
        # Find closest path
        point = Point(lng, lat, srid=settings.API_SRID)
        point.transform(settings.SRID)
        if snap is None:
            closest = Path.closest(point)
            position, offset = closest.interpolate(point)
        else:
            closest = Path.objects.get(pk=snap)
            position, offset = closest.interpolate(point)
            offset = 0
        # We can now instantiante a Topology object
        topology = TopologyFactory.create(no_path=True, kind=kind, offset=offset)
        aggrobj = PathAggregation(topo_object=topology,
                                  start_position=position,
                                  end_position=position,
                                  path=closest)
        aggrobj.save()
        point = Point(point.x, point.y, srid=settings.SRID)
        topology.geom = point
        topology.save()
        return topology

    @classmethod
    def serialize(cls, topology):
        # Point topology
        if topology.ispoint():
            geom = topology.geom_as_point()
            point = geom.transform(settings.API_SRID, clone=True)
            objdict = dict(kind=topology.kind, lng=point.x, lat=point.y)
            if topology.offset == 0:
                objdict['snap'] = topology.aggregations.all()[0].path.pk
        else:
            # Line topology
            # Fetch properly ordered aggregations
            aggregations = topology.aggregations.select_related('path').all()
            objdict = []
            current = {}
            ipath = 0
            for i, aggr in enumerate(aggregations):
                first = i == 0
                last = i == len(aggregations) - 1
                intermediary = aggr.start_position == aggr.end_position

                current.setdefault('kind', topology.kind)
                current.setdefault('offset', topology.offset)
                if not intermediary:
                    current.setdefault('paths', []).append(aggr.path.pk)
                    if not aggr.is_full or first or last:
                        current.setdefault('positions', {})[ipath] = (aggr.start_position, aggr.end_position)
                ipath = ipath + 1

                if intermediary or last:
                    objdict.append(current)
                    current = {}
                    ipath = 0
        return json.dumps(objdict)

    @classmethod
    def overlapping(cls, klass, queryset):
        from .models import Path, Topology, PathAggregation

        topology_pks = []
        if isinstance(queryset, QuerySet):
            topology_pks = [str(pk) for pk in queryset.values_list('pk', flat=True)]
        else:
            topology_pks = [str(queryset.pk)]

        sql = """
        WITH topologies AS (SELECT id FROM %(topology_table)s WHERE id IN (%(topology_list)s)),
        -- Concerned aggregations
             aggregations AS (SELECT * FROM %(aggregations_table)s a, topologies t
                              WHERE a.evenement = t.id),
        -- Concerned paths along with (start, end)
             paths_aggr AS (SELECT a.pk_debut AS start, a.pk_fin AS end, p.id
                            FROM %(paths_table)s p, aggregations a
                            WHERE a.troncon = p.id)
        -- Retrieve primary keys
        SELECT DISTINCT(t.id)
        FROM %(topology_table)s t, %(aggregations_table)s a, paths_aggr pa
        WHERE a.troncon = pa.id AND a.evenement = t.id
          AND least(a.pk_debut, a.pk_fin) <= greatest(pa.start, pa.end) AND
              greatest(a.pk_debut, a.pk_fin) >= least(pa.start, pa.end);
        """ % {
            'topology_table': Topology._meta.db_table,
            'aggregations_table': PathAggregation._meta.db_table,
            'paths_table': Path._meta.db_table,
            'topology_list': ','.join(topology_pks),
        }

        cursor = connection.cursor()
        cursor.execute(sql)
        result = cursor.fetchall()
        pks = [row[0] for row in result]
        qs = klass.objects.existing().filter(pk__in=pks)

        # Filter by kind if relevant
        if klass.KIND != Topology.KIND:
            qs = qs.filter(kind=klass.KIND)

        return qs


class PathHelper(object):
    @classmethod
    def snap(cls, path, point):
        if not path.pk:
            raise ValueError("Cannot compute snap on unsaved path")
        if point.srid != path.geom.srid:
            point.transform(path.geom.srid)
        cursor = connection.cursor()
        sql = """
        WITH p AS (SELECT ST_ClosestPoint(geom, '%(ewkt)s'::geometry) AS geom
                   FROM %(table)s
                   WHERE id = '%(pk)s')
        SELECT ST_X(p.geom), ST_Y(p.geom) FROM p
        """ % {'ewkt': point.ewkt, 'table': path._meta.db_table, 'pk': path.pk}
        cursor.execute(sql)
        result = cursor.fetchall()
        return Point(*result[0], srid=path.geom.srid)

    @classmethod
    def interpolate(cls, path, point):
        if not path.pk:
            raise ValueError("Cannot compute interpolation on unsaved path")
        if point.srid != path.geom.srid:
            point.transform(path.geom.srid)
        cursor = connection.cursor()
        sql = """
        SELECT position, distance
        FROM ft_troncon_interpolate(%(pk)s, ST_GeomFromText('POINT(%(x)s %(y)s)',%(srid)s))
             AS (position FLOAT, distance FLOAT)
        """ % {'pk': path.pk,
               'x': point.x,
               'y': point.y,
               'srid': path.geom.srid}
        cursor.execute(sql)
        result = cursor.fetchall()
        return result[0]

    @classmethod
    def disjoint(cls, geom, pk):
        """
        Returns True if this path does not overlap another.
        TODO: this could be a constraint at DB-level. But this would mean that
        path never ever overlap, even during trigger computation, like path splitting...
        """
        wkt = "ST_GeomFromText('%s', %s)" % (geom, settings.SRID)
        disjoint = sqlfunction('SELECT * FROM check_path_not_overlap', str(pk), wkt)
        return disjoint[0]


class AltimetryHelper(object):
    @classmethod
    def elevation_profile(cls, geometry3d, precision=None, offset=0):
        """Extract elevation profile from a 3D geometry.

        :precision:  geometry sampling in meters
        """
        precision = precision or settings.ALTIMETRIC_PROFILE_PRECISION

        if geometry3d.geom_type == 'MultiLineString':
            profile = []
            for subcoords in geometry3d.coords:
                subline = LineString(subcoords)
                offset += subline.length
                subprofile = AltimetryHelper.elevation_profile(subline, precision, offset)
                profile.extend(subprofile)
            return profile


        # Add measure to 2D version of geometry3d
        # Get distance from origin for each vertex
        sql = """
        WITH line2d AS (SELECT ST_force_2D('%(ewkt)s'::geometry) AS geom),
             line_measure AS (SELECT ST_Addmeasure(geom, 0, ST_length(geom)) AS geom FROM line2d),
             points2dm AS (SELECT (ST_DumpPoints(geom)).geom AS point FROM line_measure)
        SELECT (%(offset)s + ST_M(point)) FROM points2dm;
        """ % {'offset': offset, 'ewkt': geometry3d.ewkt}
        cursor = connection.cursor()
        cursor.execute(sql)
        pointsm = cursor.fetchall()
        # Join (offset+distance, x, y, z) together
        geom3dapi = geometry3d.transform(settings.API_SRID, clone=True)
        assert len(pointsm) == len(geom3dapi.coords), 'Cannot map distance to xyz'
        dxyz = [pointsm[i] + v for i, v in enumerate(geom3dapi.coords)]
        return dxyz

    @classmethod
    def profile_svg(cls, profile):
        """
        Plot the altimetric graph in SVG using PyGal.
        Most of the job done here is dedicated to preparing
        nice labels scales.
        """
        distances = [int(v[0]) for v in profile]
        elevations = [int(v[3]) for v in profile]
        min_elevation = int(min(elevations))
        floor_elevation = min_elevation - min_elevation % 10
        max_elevation = int(max(elevations))
        ceil_elevation = max_elevation + 10 - max_elevation % 10

        x_labels = distances
        y_labels = [min_elevation] + sampling(range(floor_elevation + 20, ceil_elevation - 10, 10), 3) + [max_elevation]

        # Prevent Y labels to overlap
        if len(y_labels) > 2:
            if y_labels[1] - y_labels[0] < 25:
                y_labels.pop(1)
        if len(y_labels) > 2:
            if y_labels[-1] - y_labels[-2] < 25:
                y_labels.pop(-2)

        config = dict(show_legend=False,
                      print_values=False,
                      show_dots=False,
                      x_labels_major_count=3,
                      show_minor_x_labels=False,
                      margin=settings.ALTIMETRIC_PROFILE_FONTSIZE,
                      width=settings.ALTIMETRIC_PROFILE_WIDTH,
                      height=settings.ALTIMETRIC_PROFILE_HEIGHT,
                      title_font_size=settings.ALTIMETRIC_PROFILE_FONTSIZE,
                      label_font_size=0.8 * settings.ALTIMETRIC_PROFILE_FONTSIZE,
                      major_label_font_size=settings.ALTIMETRIC_PROFILE_FONTSIZE,
                      js=[])

        style = LightSolarizedStyle
        style.background = settings.ALTIMETRIC_PROFILE_BACKGROUND
        style.colors = (settings.ALTIMETRIC_PROFILE_COLOR,)
        line_chart = pygal.StackedLine(fill=True, style=style, **config)
        line_chart.x_title = unicode(_("Distance (m)"))
        line_chart.x_labels = [str(i) for i in x_labels]
        line_chart.y_title = unicode(_("Altitude (m)"))
        line_chart.y_labels = [str(i) for i in y_labels]
        line_chart.range = [floor_elevation, max_elevation]
        line_chart.add('', elevations)
        return line_chart.render()
