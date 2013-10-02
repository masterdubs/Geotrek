from django.utils.translation import ugettext_lazy as _

import floppyforms as forms

from geotrek.common.forms import CommonForm
from .models import Path
from .helpers import PathHelper
from .fields import TopologyField, SnappedLineStringField


class TopologyForm(CommonForm):
    """
    This form is a bit specific :

        We use an extra field (topology) in order to edit the whole model instance.
        The whole instance, because we use concrete inheritance for topology models.
        Thus, at init, we load the instance into field, and at save, we
        save the field into the instance.

    The geom field is fully ignored, since we edit a topology.
    """
    topology = TopologyField(label="")

    geomfields = ['topology']

    class Meta(CommonForm.Meta):
        fields = CommonForm.Meta.fields + ['topology']

    def __init__(self, *args, **kwargs):
        super(TopologyForm, self).__init__(*args, **kwargs)
        if self.instance and self.instance.pk:
            self.fields['topology'].initial = self.instance

    def clean(self, *args, **kwargs):
        data = super(TopologyForm, self).clean()
        # geom is computed at db-level and never edited
        if 'geom' in self.errors:
            del self.errors['geom']
        return data

    def save(self, *args, **kwargs):
        topology = self.cleaned_data.pop('topology')
        instance = super(TopologyForm, self).save(*args, **kwargs)
        instance.mutate(topology)
        return instance


class PathForm(CommonForm):
    geom = SnappedLineStringField()

    reverse_geom = forms.BooleanField(required=False,
                                      label=_("Reverse path"),
                                      help_text=_("The path will be reversed once saved"))

    geomfields = ['geom']

    class Meta(CommonForm.Meta):
        model = Path
        fields = CommonForm.Meta.fields + \
            ['structure',
             'name', 'stake', 'comfort', 'trail', 'departure', 'arrival', 'comments',
             'datasource', 'networks', 'usages', 'valid', 'reverse_geom', 'geom']

    def __init__(self, *args, **kwargs):
        super(PathForm, self).__init__(*args, **kwargs)
        self.fields['geom'].label = ''

    def clean_geom(self):
        geom = self.cleaned_data['geom']
        if geom is None:
            raise forms.ValidationError(_("Invalid snapped geometry."))
        if not geom.simple:
            raise forms.ValidationError(_("Geometry is not simple."))
        if not PathHelper.disjoint(geom, self.cleaned_data.get('pk') or -1):
            raise forms.ValidationError(_("Geometry overlaps another."))
        return geom

    def save(self, commit=True):
        path = super(PathForm, self).save(commit=False)

        if self.cleaned_data.get('reverse_geom'):
            path.reverse()

        if commit:
            path.save()
            self.save_m2m()

        return path
