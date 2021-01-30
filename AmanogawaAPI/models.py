from django.db import models
from django.contrib.gis.db import models as models_geo




# Create your models here.
# class EventType(models.Model):
#     name            = models.CharField(max_length=128)
#
#     def __str__(self):
#         return self.name

class Event(models.Model):
    begin           = models.DateField()
    end             = models.DateField(blank=True)
    geolocation     = models_geo.PointField()
    name            = models.CharField(max_length=128)
    description     = models.TextField(blank=True)
    wiki_link       = models.URLField(blank=True)
    type            = models.CharField(max_length=128, blank=True)

    def __str__(self):
        return self.name


# class RelativeEventType(models.Model):
#     name            = models.CharField(max_length=128)
#
#     def __str__(self):
#         return self.name
#
# class RelativeEvent(models.Model):
#     first_event     = models.ForeignKey(Event, on_delete=models.CASCADE, related_name='topic_first_event')
#     second_event    = models.ForeignKey(Event, on_delete=models.CASCADE, related_name='topic_second_event')
#     type            = models.ForeignKey(RelativeEventType, blank=True, on_delete=models.PROTECT)
