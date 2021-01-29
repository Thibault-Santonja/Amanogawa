from django.shortcuts import render
from rest_framework import viewsets

from .serializers import EventSerializer
from .models import Event


# Create your views here.
class EventViewSet(viewsets.ModelViewSet):
    # 'ModelViewSet' is a special view that Django Rest Framework provides.
    # It will handle GET and POST for Heroes without us having to do any more work.
    queryset = Event.objects.all().order_by('begin')
    serializer_class = EventSerializer
