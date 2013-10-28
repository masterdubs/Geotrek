DROP TRIGGER IF EXISTS l_t_troncon_00_snap_geom_iu_tgr ON l_t_troncon;

CREATE OR REPLACE FUNCTION troncons_snap_extremities() RETURNS trigger AS $$
DECLARE
    linestart geometry;
    lineend geometry;
    other geometry;
    result geometry;
    newline geometry[];
    d float8;

    DISTANCE float8;
BEGIN
    DISTANCE := 1;

    linestart := ST_StartPoint(NEW.geom);
    lineend := ST_EndPoint(NEW.geom);

    result := NULL;
    SELECT ST_ClosestPoint(geom, linestart), geom INTO result, other
      FROM l_t_troncon
      WHERE geom && ST_Buffer(NEW.geom, DISTANCE * 2)
        AND id != NEW.id
        AND ST_Distance(geom, linestart) < DISTANCE
      ORDER BY ST_Distance(geom, linestart)
      LIMIT 1;

    IF result IS NULL THEN
        result := linestart;
    ELSE
        d := DISTANCE;
        FOR i IN 1..ST_NPoints(other) LOOP
            IF ST_Distance(result, ST_PointN(other, i)) < DISTANCE AND ST_Distance(result, ST_PointN(other, i)) < d THEN
                d := ST_Distance(result, ST_PointN(other, i));
                result := ST_PointN(other, i);
            END IF;
        END LOOP;
        IF NOT ST_Equals(linestart, result) THEN
            RAISE NOTICE 'Snapped start % to %, from %', ST_AsText(linestart), ST_AsText(result), ST_AsText(other);
        END IF;
    END IF;
    newline := array_append(newline, result);

    FOR i IN 2..ST_NPoints(NEW.geom)-1 LOOP
        newline := array_append(newline, ST_PointN(NEW.geom, i));
    END LOOP;

    result := NULL;
    SELECT ST_ClosestPoint(geom, lineend), geom INTO result, other

      FROM l_t_troncon
      WHERE geom && ST_Buffer(NEW.geom, DISTANCE * 2)
        AND id != NEW.id
        AND ST_Distance(geom, lineend) < DISTANCE
      ORDER BY ST_Distance(geom, lineend)
      LIMIT 1;
    IF result IS NULL THEN
        result := lineend;
    ELSE
        d := DISTANCE;
        FOR i IN 1..ST_NPoints(other) LOOP
            IF ST_Distance(result, ST_PointN(other, i)) < DISTANCE AND ST_Distance(result, ST_PointN(other, i)) < d THEN
                d := ST_Distance(result, ST_PointN(other, i));
                result := ST_PointN(other, i);
            END IF;
        END LOOP;
        IF NOT ST_Equals(lineend, result) THEN
            RAISE NOTICE 'Snapped end % to %, from %', ST_AsText(lineend), ST_AsText(result), ST_AsText(other);
        END IF;
    END IF;
    newline := array_append(newline, result);

    RAISE NOTICE 'New geom %', ST_AsText(ST_MakeLine(newline));
    NEW.geom := ST_MakeLine(newline);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER l_t_troncon_00_snap_geom_iu_tgr
BEFORE INSERT OR UPDATE OF geom ON l_t_troncon
FOR EACH ROW EXECUTE PROCEDURE troncons_snap_extremities();


-------------------------------------------------------------------------------
-- Split paths when crossing each other
-------------------------------------------------------------------------------

DROP TRIGGER IF EXISTS l_t_troncon_split_geom_iu_tgr ON l_t_troncon;
DROP TRIGGER IF EXISTS l_t_troncon_10_split_geom_iu_tgr ON l_t_troncon;

CREATE OR REPLACE FUNCTION troncons_evenement_intersect_split() RETURNS trigger AS $$
DECLARE
    troncon record;
    tid_clone integer;
    t_count integer;
    existing_et integer[];
    t_geom geometry;

    fraction float8;
    a float8;
    b float8;
    segment geometry;
    newgeom geometry;

    intersections_on_new float8[];
    intersections_on_current float8[];
BEGIN

    -- Copy original geometry
    newgeom := NEW.geom;
    intersections_on_new := ARRAY[0::float];

    -- Iterate paths intersecting, excluding those touching by extremities
    FOR troncon IN SELECT *
                   FROM l_t_troncon t
                   WHERE id != NEW.id
                         AND ST_Intersects(geom, NEW.geom)
                         AND NOT ST_Relate(geom, NEW.geom, 'FF*F*****')
                         AND GeometryType(ST_Intersection(geom, NEW.geom)) IN ('POINT', 'MULTIPOINT')
    LOOP

        RAISE NOTICE '%-% (%) intersects %-% (%) : %', NEW.id, NEW.nom, ST_AsText(NEW.geom), troncon.id, troncon.nom, ST_AsText(troncon.geom), ST_AsText(ST_Intersection(troncon.geom, NEW.geom));

        -- Locate intersecting point(s) on NEW, for later use
        FOR fraction IN SELECT ST_Line_Locate_Point(NEW.geom, (ST_Dump(ST_Intersection(troncon.geom, NEW.geom))).geom)
        LOOP
            intersections_on_new := array_append(intersections_on_new, fraction);
        END LOOP;
        intersections_on_new := array_append(intersections_on_new, 1::float);

        -- Sort intersection points and remove duplicates (0 and 1 can appear twice)
        SELECT array_agg(sub.fraction) INTO intersections_on_new
            FROM (SELECT DISTINCT unnest(intersections_on_new) AS fraction ORDER BY fraction) AS sub;

        -- Locate intersecting point(s) on current path (array of  : {0, 0.32, 0.89, 1})
        intersections_on_current := ARRAY[0::float];
        FOR fraction IN SELECT ST_Line_Locate_Point(troncon.geom, (ST_Dump(ST_Intersection(troncon.geom, NEW.geom))).geom)
        LOOP
            intersections_on_current := array_append(intersections_on_current, fraction);
        END LOOP;
        intersections_on_current := array_append(intersections_on_current, 1::float);

        -- Sort intersection points and remove duplicates (0 and 1 can appear twice)
        SELECT array_agg(sub.fraction) INTO intersections_on_current
            FROM (SELECT DISTINCT unnest(intersections_on_current) AS fraction ORDER BY fraction) AS sub;

        IF array_length(intersections_on_new, 1) > 2 AND array_length(intersections_on_current, 1) > 2 THEN
            -- If both intersects, one is enough, since split trigger will be applied recursively.
            intersections_on_new := ARRAY[]::float[];
        END IF;

    --------------------------------------------------------------------
    -- 1. Handle NEW intersecting with existing paths
    --------------------------------------------------------------------

        -- Skip if intersections are 0,1 (means not crossing)
        IF array_length(intersections_on_new, 1) > 2 THEN
            RAISE NOTICE 'New: % % intersecting on NEW % % : %', NEW.id, NEW.nom, troncon.id, troncon.nom, intersections_on_new;

            FOR i IN 1..(array_length(intersections_on_new, 1) - 1)
            LOOP
                a := intersections_on_new[i];
                b := intersections_on_new[i+1];

                segment := ST_Line_Substring(newgeom, a, b);

                IF coalesce(ST_Length(segment), 0) < 1 THEN
                     intersections_on_new[i+1] := a;
                     CONTINUE;
                END IF;

                IF i = 1 THEN
                    -- First segment : shrink it !
                    SELECT COUNT(*) INTO t_count FROM l_t_troncon WHERE nom = NEW.nom AND ST_Equals(geom, segment);
                    IF t_count = 0 THEN
                        RAISE NOTICE 'New: Skrink %-% (%) to %', NEW.id, NEW.nom, ST_AsText(NEW.geom), ST_AsText(segment);
                        UPDATE l_t_troncon SET geom = segment WHERE id = NEW.id;
                    END IF;
                ELSE
                    -- Next ones : create clones !
                    SELECT COUNT(*) INTO t_count FROM l_t_troncon WHERE nom = NEW.nom AND ST_Equals(geom, segment);
                    IF t_count = 0 THEN
                        RAISE NOTICE 'New: Create clone of %-% with geom %', NEW.id, NEW.nom, ST_AsText(segment);
                        INSERT INTO l_t_troncon (structure,
                                              valide,
                                              nom,
                                              remarques,
                                              sentier,
                                              source,
                                              enjeu,
                                              geom_cadastre,
                                              depart,
                                              arrivee,
                                              confort,
                                              geom)
                            VALUES (NEW.structure,
                                    NEW.valide,
                                    NEW.nom,
                                    NEW.remarques,
                                    NEW.sentier,
                                    NEW.source,
                                    NEW.enjeu,
                                    NEW.geom_cadastre,
                                    NEW.depart,
                                    NEW.arrivee,
                                    NEW.confort,
                                    segment)
                            RETURNING id INTO tid_clone;
                    END IF;
                END IF;
            END LOOP;

            -- Recursive triggers did all the work. Stop here.
            RETURN NULL;
        END IF;


    --------------------------------------------------------------------
    -- 2. Handle paths intersecting with NEW
    --------------------------------------------------------------------

        -- Skip if intersections are 0,1 (means not crossing)
        IF array_length(intersections_on_current, 1) > 2 THEN
            RAISE NOTICE 'Current: % % intersecting on current % % : %', NEW.id, NEW.nom, troncon.id, troncon.nom, intersections_on_current;

            SELECT array_agg(id) INTO existing_et FROM e_r_evenement_troncon et WHERE et.troncon = troncon.id;
             IF existing_et IS NOT NULL THEN
                 RAISE NOTICE 'Existing topologies id for %-% (%): %', troncon.id, troncon.nom, ST_AsText(troncon.geom), existing_et;
             END IF;

            FOR i IN 1..(array_length(intersections_on_current, 1) - 1)
            LOOP
                a := intersections_on_current[i];
                b := intersections_on_current[i+1];

                segment := ST_Line_Substring(troncon.geom, a, b);

                IF coalesce(ST_Length(segment), 0) < 1 THEN
                     intersections_on_new[i+1] := a;
                     CONTINUE;
                END IF;

                IF i = 1 THEN
                    -- First segment : shrink it !
                    SELECT geom INTO t_geom FROM l_t_troncon WHERE id = troncon.id;
                    IF NOT ST_Equals(t_geom, segment) THEN
                        RAISE NOTICE 'Current: Skrink %-% (%) to %', troncon.id, troncon.nom, ST_AsText(troncon.geom), ST_AsText(segment);
                        UPDATE l_t_troncon SET geom = segment WHERE id = troncon.id;
                    END IF;
                ELSE
                    -- Next ones : create clones !
                    SELECT COUNT(*) INTO t_count FROM l_t_troncon WHERE ST_Equals(geom, segment);
                    IF t_count = 0 THEN
                        RAISE NOTICE 'Current: Create clone of %-% (%) with geom %', troncon.id, troncon.nom, ST_AsText(troncon.geom), ST_AsText(segment);
                        INSERT INTO l_t_troncon (structure,
                                              valide,
                                              nom,
                                              remarques,
                                              sentier,
                                              source,
                                              enjeu,
                                              geom_cadastre,
                                              depart,
                                              arrivee,
                                              confort,
                                              geom)
                            VALUES (troncon.structure,
                                    troncon.valide,
                                    troncon.nom,
                                    troncon.remarques,
                                    troncon.sentier,
                                    troncon.source,
                                    troncon.enjeu,
                                    troncon.geom_cadastre,
                                    troncon.depart,
                                    troncon.arrivee,
                                    troncon.confort,
                                    segment)
                            RETURNING id INTO tid_clone;

                        -- Copy N-N relations
                        INSERT INTO l_r_troncon_reseau (path_id, network_id)
                            SELECT tid_clone, tr.network_id
                            FROM l_r_troncon_reseau tr
                            WHERE tr.path_id = troncon.id;
                        INSERT INTO l_r_troncon_usage (path_id, usage_id)
                            SELECT tid_clone, tr.usage_id
                            FROM l_r_troncon_usage tr
                            WHERE tr.path_id = troncon.id;

                        -- Copy topologies overlapping start/end
                        INSERT INTO e_r_evenement_troncon (troncon, evenement, pk_debut, pk_fin)
                            SELECT
                                tid_clone,
                                et.evenement,
                                CASE WHEN pk_debut <= pk_fin THEN
                                    (greatest(a, pk_debut) - a) / (b - a)
                                ELSE
                                    (least(b, pk_debut) - a) / (b - a)
                                END,
                                CASE WHEN pk_debut <= pk_fin THEN
                                    (least(b, pk_fin) - a) / (b - a)
                                ELSE
                                    (greatest(a, pk_fin) - a) / (b - a)
                                END
                            FROM e_r_evenement_troncon et,
                                 e_t_evenement e
                            WHERE et.evenement = e.id
                                  AND et.troncon = troncon.id
                                  AND ((least(pk_debut, pk_fin) < b AND greatest(pk_debut, pk_fin) > a) OR       -- Overlapping
                                       (pk_debut = pk_fin AND pk_debut = a AND decallage = 0)); -- Point
                        GET DIAGNOSTICS t_count = ROW_COUNT;
                        IF t_count > 0 THEN
                            RAISE NOTICE 'Duplicated % topologies of %-% (%) on [% ; %] for %-% (%)', t_count, troncon.id, troncon.nom, ST_AsText(troncon.geom), a, b, tid_clone, troncon.nom, ST_AsText(segment);
                        END IF;
                        -- Special case : point topology at the end of path
                        IF b = 1 THEN
                            SELECT geom INTO t_geom FROM l_t_troncon WHERE id = troncon.id;
                            fraction := ST_Line_Locate_Point(segment, ST_EndPoint(troncon.geom));
                            INSERT INTO e_r_evenement_troncon (troncon, evenement, pk_debut, pk_fin)
                                SELECT tid_clone, evenement, pk_debut, pk_fin
                                FROM e_r_evenement_troncon et,
                                     e_t_evenement e
                                WHERE et.evenement = e.id AND
                                      et.troncon = troncon.id AND
                                      pk_debut = pk_fin AND
                                      pk_debut = 1 AND
                                      decallage = 0;
                            GET DIAGNOSTICS t_count = ROW_COUNT;
                            IF t_count > 0 THEN
                                RAISE NOTICE 'Duplicated % point topologies of %-% (%) on intersection at the end of %-% (%) at [%]', t_count, troncon.id, troncon.nom, ST_AsText(t_geom), tid_clone, troncon.nom, ST_AsText(segment), fraction;
                            END IF;
                        END IF;
                        -- Special case : point topology exactly where NEW path intersects
                        IF a > 0 THEN
                            fraction := ST_Line_Locate_Point(NEW.geom, ST_Line_Interpolate_Point(troncon.geom, a));
                            INSERT INTO e_r_evenement_troncon (troncon, evenement, pk_debut, pk_fin)
                                SELECT NEW.id, et.evenement, fraction, fraction
                                FROM e_r_evenement_troncon et,
                                     e_t_evenement e
                                WHERE et.evenement = e.id
                                  AND et.troncon = troncon.id
                                  AND pk_debut = pk_fin AND pk_debut = a
                                  AND decallage = 0;
                            GET DIAGNOSTICS t_count = ROW_COUNT;
                            IF t_count > 0 THEN
                                RAISE NOTICE 'Duplicated % point topologies of %-% (%) on intersection by %-% (%) at [%]', t_count, troncon.id, troncon.nom, ST_AsText(troncon.geom), NEW.id, NEW.nom, ST_AsText(NEW.geom), a;
                            END IF;
                        END IF;
                    END IF;
                END IF;
            END LOOP;


            -- For each existing point topology with offset, re-attach it
            -- to the closest path, among those splitted.
            WITH existing_rec AS (SELECT et.id, e.decallage, e.geom
                                    FROM e_r_evenement_troncon et,
                                         e_t_evenement e
                                   WHERE et.evenement = e.id
                                     AND et.pk_debut = et.pk_debut
                                     AND e.decallage > 0
                                     AND et.troncon = troncon.id
                                     AND et.id = ANY(existing_et)),
                 closest_path AS (SELECT er.id AS et_id, t.id AS closest_id
                                    FROM l_t_troncon t, existing_rec er
                                   WHERE t.id != troncon.id
                                     AND ST_Distance(er.geom, t.geom) < er.decallage
                                ORDER BY ST_Distance(er.geom, t.geom)
                                   LIMIT 1)
                UPDATE e_r_evenement_troncon SET troncon = closest_id
                  FROM closest_path
                 WHERE id = et_id;
            GET DIAGNOSTICS t_count = ROW_COUNT;
            IF t_count > 0 THEN
                -- Update geom of affected paths to trigger update_evenement_geom_when_troncon_changes()
                UPDATE l_t_troncon t SET geom = geom
                  FROM e_r_evenement_troncon et
                 WHERE t.id = et.troncon
                   AND et.pk_debut = et.pk_debut
                   AND et.id = ANY(existing_et);
            END IF;

            -- Update point topologies at intersection
            -- Trigger e_r_evenement_troncon_junction_point_iu_tgr
            UPDATE e_r_evenement_troncon et SET pk_debut = pk_debut
             WHERE et.troncon = NEW.id
               AND pk_debut = pk_fin;

            -- Now handle first path topologies
            a := intersections_on_current[1];
            b := intersections_on_current[2];
            DELETE FROM e_r_evenement_troncon et WHERE et.troncon = troncon.id
                                                 AND id = ANY(existing_et)
                                                 AND (least(pk_debut, pk_fin) > b OR greatest(pk_debut, pk_fin) < a);
            GET DIAGNOSTICS t_count = ROW_COUNT;
            IF t_count > 0 THEN
                RAISE NOTICE 'Removed % topologies of %-% on [% ; %]', t_count, troncon.id,  troncon.nom, a, b;
            END IF;

            -- Update topologies overlapping
            UPDATE e_r_evenement_troncon et SET
                pk_debut = CASE WHEN pk_debut / (b - a) > 1 THEN 1 ELSE pk_debut / (b - a) END,
                pk_fin = CASE WHEN pk_fin / (b - a) > 1 THEN 1 ELSE pk_fin / (b - a) END
                WHERE et.troncon = troncon.id
                AND least(pk_debut, pk_fin) <= b AND greatest(pk_debut, pk_fin) >= a;
            GET DIAGNOSTICS t_count = ROW_COUNT;
            IF t_count > 0 THEN
                RAISE NOTICE 'Updated % topologies of %-% on [% ; %]', t_count, troncon.id,  troncon.nom, a, b;
            END IF;
        END IF;


    END LOOP;

    IF array_length(intersections_on_new, 1) > 0 OR array_length(intersections_on_current, 1) > 0 THEN
        RAISE NOTICE 'Done %-% (%).', NEW.id, NEW.nom, ST_AsText(NEW.geom);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER l_t_troncon_10_split_geom_iu_tgr
AFTER INSERT OR UPDATE OF geom ON l_t_troncon
FOR EACH ROW EXECUTE PROCEDURE troncons_evenement_intersect_split();
