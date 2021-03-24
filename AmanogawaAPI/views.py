from rest_framework import viewsets

from .serializers import EventSerializer, CountrySerializer
from .models import Event, Country

import datetime


# Create your views here.
class EventViewSet(viewsets.ModelViewSet):
    # 'ModelViewSet' is a special view that Django Rest Framework provides.
    # It will handle GET and POST for Event without us having to do any more work.
    queryset = Event.objects.all().order_by('begin')
    serializer_class = EventSerializer

    def get_queryset(self):
        start = self.request.GET.get('start', None)
        end = self.request.GET.get('end', None)

        if start and end:
            if int(start) <= 0:
                start = 1
            else:
                start = int(start)
            end = int(end)
            return Event.objects.all().filter(
                begin__range=(datetime.datetime(start, 1, 1), datetime.datetime(end, 1, 1))).order_by('begin')
        else:
            return Event.objects.all().order_by('begin')


# Create your views here.
class CountryViewSet(viewsets.ModelViewSet):
    # 'ModelViewSet' is a special view that Django Rest Framework provides.
    # It will handle GET and POST for Event without us having to do any more work.
    queryset = Country.objects.all().order_by('creation')
    serializer_class = CountrySerializer

    def get_queryset(self):
        start = self.request.GET.get('start', None)
        end = self.request.GET.get('end', None)

        if start and end:
            if int(start) <= 0:
                start = 1
            else:
                start = int(start)
            end = int(end)
            return Country.objects.all().filter(
                begin__range=(datetime.datetime(start, 1, 1), datetime.datetime(end, 1, 1))).order_by('creation')
        else:
            return Country.objects.all().order_by('creation')
'''
@api_view(['GET', 'PUT', 'DELETE'])
def snippet_detail(request, pk):
    """
    Retrieve, update or delete a code snippet.
    """
    try:
        snippet = Snippet.objects.get(pk=pk)
    except Snippet.DoesNotExist:
        return Response(status=status.HTTP_404_NOT_FOUND)

    if request.method == 'GET':
        serializer = SnippetSerializer(snippet)
        return Response(serializer.data)
'''
