from rest_framework import serializers

from .models import Event, Country


class EventSerializer(serializers.HyperlinkedModelSerializer):
    class Meta:
        model = Event
        fields = ('begin', 'end', 'name', 'geolocation', 'description', 'extract', 'wiki_link', 'API_wiki_link', 'type')


class CountrySerializer(serializers.HyperlinkedModelSerializer):
    class Meta:
        model = Country
        fields = (
            'creation', 'dissolve', 'name', 'geolocations', 'description', 'extract', 'wiki_link', 'API_wiki_link',
            'type')
