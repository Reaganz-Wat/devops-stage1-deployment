from django.shortcuts import render
from django.http import JsonResponse
from datetime import datetime

def home(request):
    return JsonResponse({
        'message': 'Hello from DevOps Stage 1 - Django!',
        'status': 'success',
        'timestamp': datetime.now().isoformat()
    })

def health(request):
    return JsonResponse({'status': 'healthy'})