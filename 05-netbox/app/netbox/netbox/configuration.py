import os

DATABASE = {
    'NAME': 'netbox',
    'USER': 'netbox',
    'PASSWORD': 'netboxpassword',
    'HOST': 'netbox-db',
    'PORT': '',
}

REDIS = {
    'tasks': {'HOST': 'netbox-redis', 'PORT': 6379, 'DATABASE': 0},
    'caching': {'HOST': 'netbox-redis', 'PORT': 6379, 'DATABASE': 1},
}

SECRET_KEY = 'nix-reproducible-secret-key-for-hive-lab-this-key-is-now-long-enough'
ALLOWED_HOSTS = ['*']

# PRODUCTION MODE: This disables the crashing Debug Toolbar logic
DEBUG = False

# NIX PERMISSION FIXES
STATIC_ROOT = '/app/netbox/static'
MEDIA_ROOT = '/app/netbox/media'
STORAGE_BACKEND = 'django.core.files.storage.FileSystemStorage'
STORAGE_CONFIG = {'location': '/tmp'}
