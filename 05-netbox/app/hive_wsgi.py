# HIVE Phase 05 — WSGI entry point for NetBox.
#
# Why this exists: with DEBUG = False, Django stops serving /static/ and
# whitenoise is the standard fix. But NetBox 4.0's settings.py never reads
# middleware settings from configuration.py (EXTRA_MIDDLEWARE and
# MIDDLEWARE are both ignored — MIDDLEWARE is a hardcoded list extended only
# by plugins), so the middleware is injected here instead, before
# get_wsgi_application() builds the chain.

import os

import django

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "netbox.settings")
django.setup()

from django.conf import settings  # noqa: E402
from whitenoise.middleware import WhiteNoiseMiddleware  # noqa: E402

# Keep PrometheusBeforeMiddleware (settings.MIDDLEWARE[0]) outermost so
# request metrics still bookend requests that whitenoise short-circuits.
settings.MIDDLEWARE.insert(1, "whitenoise.middleware.WhiteNoiseMiddleware")

from django.core.wsgi import get_wsgi_application  # noqa: E402

application = get_wsgi_application()
