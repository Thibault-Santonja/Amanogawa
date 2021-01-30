from django.db import models
from django.contrib.gis.db import models as models_geo


# Create your models here.
class Event(models.Model):
    begin           = models.DateField()
    end             = models.DateField(blank=True)
    geolocation     = models_geo.PointField()
    name            = models.CharField(max_length=128)
    description     = models.TextField(blank=True)
    wiki_link       = models.URLField(blank=True)

    def __str__(self):
        return self.name
