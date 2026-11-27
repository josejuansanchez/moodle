#!/bin/bash
# =============================================================================
#  02-setup-letsencrypt.sh
#
#  1. Crea el sitio web (VirtualHost) de Apache para el dominio de Moodle.
#  2. Solicita un certificado TLS gratuito a Let's Encrypt con Certbot.
#  3. Configura HTTPS y redirige automáticamente HTTP -> HTTPS.
#
#  Se ejecuta ANTES de instalar Moodle para que el sitio funcione con HTTPS
#  desde el primer momento (Moodle guarda su URL, https://..., al instalarse).
#
#  Requisitos:
#    - Haber ejecutado 01-install-lamp.sh
#    - El dominio debe apuntar a la IP pública de esta máquina
#    - El puerto 80 debe estar abierto (Let's Encrypt lo usa para validar)
#
#  Uso:  sudo ./02-setup-letsencrypt.sh
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Paso 1. Cargar las variables del fichero .env
# -----------------------------------------------------------------------------
cd "$(dirname "$0")"
source .env

for VAR in DOMAIN LE_EMAIL; do
  if [ -z "${!VAR:-}" ]; then
    echo "ERROR: la variable $VAR está vacía en el fichero .env" >&2
    exit 1
  fi
done

# Directorio donde se instalará Moodle. Desde Moodle 5.1 la parte accesible
# desde la web es la subcarpeta "public".
MOODLE_DIR=/var/www/moodle

# Directorio con las plantillas de configuración.
TEMPLATES="$(pwd)/templates"

# envsubst solo ve las variables "exportadas" (variables de entorno).
export DOMAIN MOODLE_DIR

set -x

# -----------------------------------------------------------------------------
# Paso 2. Comprobar que el dominio apunta a esta máquina
# Si no es así, Let's Encrypt no podrá validar el dominio.
# -----------------------------------------------------------------------------
IP_PUBLICA=$(curl -s https://checkip.amazonaws.com)
IP_DOMINIO=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}')

if [ "$IP_PUBLICA" != "$IP_DOMINIO" ]; then
  echo "ERROR: $DOMAIN apunta a '$IP_DOMINIO' pero la IP de esta máquina es '$IP_PUBLICA'" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Paso 3. Crear el VirtualHost de Apache para el dominio
#
# Certbot necesita un sitio con "ServerName <dominio>" para saber dónde
# configurar el certificado. Lo creamos ya con la configuración de Moodle.
#
# envsubst lee la plantilla y sustituye ${DOMAIN} y ${MOODLE_DIR} por sus
# valores. Indicamos la lista de variables para que NO toque otras, como
# ${APACHE_LOG_DIR}, que debe llegar tal cual a Apache.
# -----------------------------------------------------------------------------
mkdir -p "$MOODLE_DIR/public"

envsubst '${DOMAIN} ${MOODLE_DIR}' \
  < "$TEMPLATES/apache/moodle.conf" \
  > /etc/apache2/sites-available/moodle.conf

# Activamos nuestro sitio, desactivamos el sitio de ejemplo de Apache y
# comprobamos que la configuración es correcta antes de recargar.
a2ensite moodle
a2dissite 000-default
apache2ctl configtest
systemctl reload apache2

# -----------------------------------------------------------------------------
# Paso 4. Instalar Certbot
# El método recomendado por sus autores (la EFF) es el paquete snap.
# -----------------------------------------------------------------------------
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# -----------------------------------------------------------------------------
# Paso 5. Solicitar el certificado y configurar Apache
#
#   --apache          usa el plugin de Apache: valida el dominio y crea el
#                     VirtualHost HTTPS (moodle-le-ssl.conf) automáticamente
#   -d                dominio para el que se pide el certificado
#   -m                email de contacto para avisos de caducidad
#   --agree-tos       acepta los términos de servicio de Let's Encrypt
#   --no-eff-email    no compartir el email con la EFF
#   --redirect        redirige todo el tráfico HTTP a HTTPS
#   --hsts            indica a los navegadores que usen siempre HTTPS
#   --non-interactive no hace preguntas
# -----------------------------------------------------------------------------
certbot --apache \
  -d "$DOMAIN" \
  -m "$LE_EMAIL" \
  --agree-tos --no-eff-email \
  --redirect --hsts \
  --non-interactive

# -----------------------------------------------------------------------------
# Paso 6. Comprobar la renovación automática
# Los certificados duran poco (unos 90 días o menos). Certbot instala un
# temporizador que los renueva solo; aquí simulamos una renovación.
# -----------------------------------------------------------------------------
certbot renew --dry-run

set +x
echo
echo "Certificado TLS instalado para https://$DOMAIN"
echo "Siguiente paso: sudo ./03-deploy-moodle.sh"
