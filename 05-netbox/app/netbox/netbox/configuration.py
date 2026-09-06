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

# 4. THE FIX: Turn off DEBUG mode
# This stops the Debug Toolbar from loading and prevents the AttributeError.
DEBUG = False

# 5. Nix Read-Only Filesystem Fixes
STATIC_ROOT = '/app/netbox/static' # We will use our volume mount here
MEDIA_ROOT = '/app/netbox/media'
STORAGE_BACKEND = 'django.core.files.storage.FileSystemStorage'
STORAGE_CONFIG = {'location': '/tmp'}
