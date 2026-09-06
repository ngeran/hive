import os
import sys

# THE HACK: This tricks NetBox into thinking the Debug Toolbar is not installed.
# This prevents the 'function object has no attribute set' error.
sys.modules['debug_toolbar'] = None

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

# 4. Lab Mode
# Keep DEBUG=True so Django serves its own CSS/Images for the lab.
DEBUG = True
DEBUG_TOOLBAR_ENABLED = False

# 5. Nix Read-Only Filesystem Fixes
# We use the 'Cheat Code' volume mounts from the manifest here.
STATIC_ROOT = '/app/netbox/static'
MEDIA_ROOT = '/app/netbox/media'
STORAGE_BACKEND = 'django.core.files.storage.FileSystemStorage'
STORAGE_CONFIG = {'location': '/tmp'}
