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

# 4. THE FIX: Production Mode
# Setting DEBUG = False removes the crashing Debug Toolbar entirely.
DEBUG = False

# 5. Whitenoise Fix
# This allows NetBox to serve its own CSS/JS even though DEBUG is False.
# NetBox 4.0 supports injecting middleware via this setting.
EXTRA_MIDDLEWARE = [
    'whitenoise.middleware.WhiteNoiseMiddleware',
]

# 6. Nix Read-Only Filesystem Fixes
STATIC_ROOT = '/app/netbox/static'
MEDIA_ROOT = '/app/netbox/media'
STORAGE_BACKEND = 'django.core.files.storage.FileSystemStorage'
STORAGE_CONFIG = {'location': '/tmp'}
