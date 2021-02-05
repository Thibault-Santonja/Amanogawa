from django.shortcuts import render
from rest_framework import viewsets

from .serializers import EventSerializer
from .models import Event


# Create your views here.
class EventViewSet(viewsets.ModelViewSet):
    # 'ModelViewSet' is a special view that Django Rest Framework provides.
    # It will handle GET and POST for Event without us having to do any more work.
    queryset = Event.objects.all().order_by('begin')
    serializer_class = EventSerializer

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
