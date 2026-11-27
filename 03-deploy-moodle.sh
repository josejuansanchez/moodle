#!/bin/bash
# =============================================================================
#  03-deploy-moodle.sh
#
#  Descarga la última versión estable de Moodle y la instala con el
#  instalador de línea de comandos (CLI) de Moodle: admin/cli/install.php
#
#  Requisitos:
#    - Haber ejecutado 01-install-lamp.sh y 02-setup-letsencrypt.sh
#
#  Uso:  sudo ./03-deploy-moodle.sh
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Paso 1. Cargar y comprobar las variables del fichero .env
# -----------------------------------------------------------------------------
cd "$(dirname "$0")"
source .env

for VAR in DOMAIN DB_NAME DB_USER DB_PASS MOODLE_SITE_FULLNAME MOODLE_SITE_SHORTNAME \
           MOODLE_LANG MOODLE_ADMIN_USER MOODLE_ADMIN_PASS MOODLE_ADMIN_EMAIL; do
  if [ -z "${!VAR:-}" ]; then
    echo "ERROR: la variable $VAR está vacía en el fichero .env" >&2
    exit 1
  fi
done

# Rutas estándar (no hace falta cambiarlas):
#   MOODLE_DIR  -> código de Moodle. La web solo ve su subcarpeta "public".
#   MOODLE_DATA -> ficheros subidos, cachés, sesiones... Debe estar FUERA de
#                  la carpeta web para que nadie pueda descargarlos.
MOODLE_DIR=/var/www/moodle
MOODLE_DATA=/var/moodledata

# Usuario con el que se ejecuta Apache/PHP en Ubuntu.
WEB_USER=www-data

# Directorio con las plantillas (ruta absoluta: más adelante cambiamos de carpeta).
TEMPLATES="$(pwd)/templates"

# envsubst solo ve las variables "exportadas" (variables de entorno).
export DB_NAME DB_USER DB_PASS MOODLE_DIR WEB_USER

# Si Moodle ya está instalado no hacemos nada, para no sobrescribir nada.
if [ -f "$MOODLE_DIR/config.php" ]; then
  echo "Moodle ya está instalado en $MOODLE_DIR (existe config.php). No se hace nada."
  exit 0
fi

set -x

# -----------------------------------------------------------------------------
# Paso 2. Averiguar cuál es la última versión estable de Moodle
#
# Cada versión estable tiene una rama en GitHub llamada MOODLE_XYZ_STABLE
# (p. ej. MOODLE_503_STABLE = Moodle 5.3). Nos quedamos con el número mayor.
# -----------------------------------------------------------------------------
MOODLE_BRANCH=$(git ls-remote --heads https://github.com/moodle/moodle.git 'MOODLE_*_STABLE' \
                | grep -oE '[0-9]+_STABLE' | cut -d_ -f1 | sort -n | tail -1)

# -----------------------------------------------------------------------------
# Paso 3. Descargar Moodle y comprobar que el fichero no está corrupto
# El servidor publica la suma SHA-256 del paquete; la comparamos con la nuestra.
# -----------------------------------------------------------------------------
URL="https://packaging.moodle.org/stable${MOODLE_BRANCH}/moodle-latest-${MOODLE_BRANCH}.tgz"
# Usamos un directorio temporal propio (mktemp) en lugar de /tmp directamente.
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
curl -fL -o moodle.tgz        "$URL"
curl -fL -o moodle.tgz.sha256 "$URL.sha256"

SUMA_ESPERADA=$(grep -oE '[0-9a-f]{64}' moodle.tgz.sha256)
SUMA_REAL=$(sha256sum moodle.tgz | cut -d' ' -f1)
if [ "$SUMA_ESPERADA" != "$SUMA_REAL" ]; then
  echo "ERROR: el paquete descargado está dañado (SHA-256 no coincide)" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Paso 4. Descomprimir Moodle en su directorio
# --strip-components=1 quita la carpeta "moodle/" que trae el paquete.
# -----------------------------------------------------------------------------
mkdir -p "$MOODLE_DIR"
tar -xzf moodle.tgz -C "$MOODLE_DIR" --strip-components=1
rm -rf "$TMP_DIR"

# -----------------------------------------------------------------------------
# Paso 5. Instalar las librerías PHP de Moodle con Composer
#   --no-dev                 sin herramientas de desarrollo (no van en producción)
#   --classmap-authoritative carga de clases optimizada (lo recomienda Moodle)
# -----------------------------------------------------------------------------
cd "$MOODLE_DIR"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --classmap-authoritative --no-interaction

# -----------------------------------------------------------------------------
# Paso 6. Crear la base de datos y su usuario
#
# envsubst rellena la plantilla SQL con DB_NAME, DB_USER y DB_PASS y el
# resultado se envía directamente a MySQL por una tubería (|). Así la
# contraseña nunca se guarda en un fichero.
# -----------------------------------------------------------------------------
envsubst '${DB_NAME} ${DB_USER} ${DB_PASS}' \
  < "$TEMPLATES/mysql/create-moodle-db.sql" | mysql

# -----------------------------------------------------------------------------
# Paso 7. Crear el directorio de datos (moodledata)
# Pertenece al usuario web porque Moodle escribe en él continuamente.
# -----------------------------------------------------------------------------
mkdir -p "$MOODLE_DATA"
chown -R "$WEB_USER:$WEB_USER" "$MOODLE_DATA"
chmod 0770 "$MOODLE_DATA"

# -----------------------------------------------------------------------------
# Paso 8. Permisos del código
#
# Buena práctica: el código pertenece a root y el servidor web solo puede
# leerlo. Así, si alguien encontrara un fallo en Moodle, no podría modificar
# el código. Solo durante la instalación dejamos que www-data escriba en la
# carpeta principal para que el instalador cree config.php.
# -----------------------------------------------------------------------------
chown -R root:root "$MOODLE_DIR"
chown "$WEB_USER" "$MOODLE_DIR"

# -----------------------------------------------------------------------------
# Paso 9. Instalar Moodle con su instalador CLI (admin/cli/install.php)
#
# Se ejecuta como www-data (sudo -u) para que los ficheros que cree Moodle
# tengan el dueño correcto. Opciones:
#   --non-interactive  no hace preguntas: todo se pasa como parámetro
#   --agree-license    acepta la licencia GPL de Moodle
#   --wwwroot          URL del sitio (ya con HTTPS, gracias al paso 02)
#   --dataroot         directorio de datos
#   --dbtype mysqli    controlador de Moodle para MySQL
#
# Desactivamos la traza (set +x) para no mostrar las contraseñas en pantalla.
# -----------------------------------------------------------------------------
set +x
echo "+ sudo -u $WEB_USER php $MOODLE_DIR/admin/cli/install.php ... (contraseñas ocultas)"
sudo -u "$WEB_USER" php "$MOODLE_DIR/admin/cli/install.php" \
  --non-interactive \
  --agree-license \
  --lang="$MOODLE_LANG" \
  --wwwroot="https://$DOMAIN" \
  --dataroot="$MOODLE_DATA" \
  --dbtype=mysqli \
  --dbhost=localhost \
  --dbname="$DB_NAME" \
  --dbuser="$DB_USER" \
  --dbpass="$DB_PASS" \
  --fullname="$MOODLE_SITE_FULLNAME" \
  --shortname="$MOODLE_SITE_SHORTNAME" \
  --adminuser="$MOODLE_ADMIN_USER" \
  --adminpass="$MOODLE_ADMIN_PASS" \
  --adminemail="$MOODLE_ADMIN_EMAIL"
set -x

# -----------------------------------------------------------------------------
# Paso 10. Completar config.php
# Indicamos a Moodle que Apache ya tiene configurado su router (FallbackResource
# /r.php en el paso 02). La línea se añade antes de "require_once ... setup.php".
# -----------------------------------------------------------------------------
sed -i '/lib\/setup.php/i $CFG->routerconfigured = true;' "$MOODLE_DIR/config.php"

# Devolvemos la carpeta a root. config.php contiene la contraseña de la base de
# datos: solo lo pueden leer root y el grupo www-data (permisos 640).
chown root:root "$MOODLE_DIR"
chown root:"$WEB_USER" "$MOODLE_DIR/config.php"
chmod 0640 "$MOODLE_DIR/config.php"

# -----------------------------------------------------------------------------
# Paso 11. Programar el cron de Moodle (cada minuto, como www-data)
# Los ficheros de /etc/cron.d deben pertenecer a root y tener permisos 644.
# -----------------------------------------------------------------------------
envsubst '${WEB_USER} ${MOODLE_DIR}' \
  < "$TEMPLATES/cron/moodle" \
  > /etc/cron.d/moodle
chmod 644 /etc/cron.d/moodle

# -----------------------------------------------------------------------------
# Paso 12. Recargar PHP-FPM para limpiar la caché OPcache
# -----------------------------------------------------------------------------
systemctl reload "php$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')-fpm"

set +x
echo
echo "Moodle instalado correctamente."
echo "  URL:            https://$DOMAIN"
echo "  Administrador:  $MOODLE_ADMIN_USER"
