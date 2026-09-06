import os

# 1. Database Settings
DATABASE = {
    'NAME': 'netbox',
    'USER': 'netbox',
    'PASSWORD': 'netboxpassword',
    'HOST': 'netbox-db',
    'PORT': '',
}

# 2. Redis Settings
REDIS = {
    'tasks': {'HOST': 'netbox-redis', 'PORT': 6379, 'DATABASE': 0},
    'caching': {'HOST': 'netbox-redis', 'PORT': 6379, 'DATABASE': 1},
}

# 3. Security Settings
SECRET_KEY = 'nix-reproducible-secret-key-for-hive-lab-this-key-is-now-long-enough'
ALLOWED_HOSTS = ['*']

# 4. Production Mode
# NOTE: the old crashes were never caused by DEBUG — they came from a
# django-debug-toolbar version drift (6.x vs the 4.3.0 NetBox pins; see
# pyproject.toml). NetBox loads its debug middleware regardless of DEBUG.
DEBUG = False

# 5. Static/media paths
# settings.py hardcodes STATIC_ROOT to <NetBox dir>/static; the manifest
# mounts an emptyDir there, so collectstatic (initContainer) can write it.
# whitenoise serving is wired in app/hive_wsgi.py — NetBox 4.0 reads no
# middleware settings from this file (EXTRA_MIDDLEWARE was never a thing).
MEDIA_ROOT = '/app/netbox/media'
STORAGE_BACKEND = 'django.core.files.storage.FileSystemStorage'
STORAGE_CONFIG = {'location': '/tmp'}
