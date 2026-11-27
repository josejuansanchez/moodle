#!/bin/bash
# =============================================================================
#  01-install-lamp.sh
#
#  Instala la pila LAMP que necesita Moodle:
#     L = Linux (Ubuntu)
#     A = Apache  -> servidor web
#     M = MySQL   -> base de datos
#     P = PHP     -> lenguaje en el que está escrito Moodle
#
#  Uso:  sudo ./01-install-lamp.sh
# =============================================================================

# Modo estricto: el script se detiene si un comando falla (-e), si se usa una
# variable sin definir (-u) o si falla cualquier comando de una tubería (pipefail).
set -euo pipefail

# Muestra cada comando antes de ejecutarlo, útil para aprender y depurar.
set -x

# Evita que apt haga preguntas durante la instalación.
export DEBIAN_FRONTEND=noninteractive

# Directorio con las plantillas de configuración (junto a este script).
TEMPLATES="$(dirname "$(readlink -f "$0")")/templates"

# -----------------------------------------------------------------------------
# Paso 1. Actualizar la lista de paquetes y el sistema
# -----------------------------------------------------------------------------
apt-get update
apt-get upgrade -y

# -----------------------------------------------------------------------------
# Paso 2. Instalar Apache
# -----------------------------------------------------------------------------
apt-get install -y apache2

# -----------------------------------------------------------------------------
# Paso 3. Instalar PHP y las extensiones que exige Moodle
#
#   php-fpm   -> ejecuta PHP como un servicio aparte (más eficiente que mod_php)
#   php-mysql -> conexión con MySQL
#   resto     -> extensiones requeridas por Moodle (xml, mbstring, curl, zip,
#                gd para imágenes, intl para idiomas, soap para servicios web...)
# -----------------------------------------------------------------------------
apt-get install -y php-fpm php-cli php-mysql php-xml php-mbstring php-curl \
                   php-zip php-gd php-intl php-soap php-bcmath

# Composer: gestor de dependencias PHP. Moodle (>= 5.1) lo necesita para
# descargar sus librerías externas.
apt-get install -y composer unzip

# Averiguamos la versión de PHP instalada (por ejemplo "8.5").
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')

# -----------------------------------------------------------------------------
# Paso 4. Conectar Apache con PHP-FPM
#
#   - mpm_event: modo de trabajo de Apache recomendado junto con PHP-FPM.
#   - proxy_fcgi: Apache pasa las peticiones .php a PHP-FPM.
#   - rewrite y headers: los usaremos en la configuración del sitio.
# -----------------------------------------------------------------------------
a2dismod mpm_prefork || true
a2enmod mpm_event proxy_fcgi setenvif rewrite headers ssl
a2enconf "php${PHP_VERSION}-fpm"

# -----------------------------------------------------------------------------
# Paso 5. Ajustar PHP para Moodle
#
# Copiamos la plantilla templates/php/99-moodle.ini al directorio conf.d de
# PHP-FPM (web) y de PHP-CLI (cron e instalador).
# "install -m 644" copia el fichero y le da permisos de lectura para todos.
# -----------------------------------------------------------------------------
install -m 644 "$TEMPLATES/php/99-moodle.ini" "/etc/php/${PHP_VERSION}/fpm/conf.d/99-moodle.ini"
install -m 644 "$TEMPLATES/php/99-moodle.ini" "/etc/php/${PHP_VERSION}/cli/conf.d/99-moodle.ini"

# -----------------------------------------------------------------------------
# Paso 6. Instalar MySQL
#
# En Ubuntu, el usuario root de MySQL se autentica por "socket": solo el root
# del sistema puede entrar (sudo mysql), así que no necesita contraseña.
# -----------------------------------------------------------------------------
apt-get install -y mysql-server

# -----------------------------------------------------------------------------
# Paso 7. Herramientas que Moodle usa opcionalmente
#   ghostscript -> anotar PDFs en las tareas
#   graphviz    -> dibujar gráficos
#   aspell      -> corrector ortográfico
# -----------------------------------------------------------------------------
apt-get install -y ghostscript graphviz aspell aspell-es

# -----------------------------------------------------------------------------
# Paso 8. Endurecer Apache (buena práctica de seguridad)
# La plantilla oculta la versión de Apache y desactiva el método TRACE.
# -----------------------------------------------------------------------------
install -m 644 "$TEMPLATES/apache/security.conf" /etc/apache2/conf-available/security.conf
a2enconf security

# -----------------------------------------------------------------------------
# Paso 9. Cortafuegos: solo permitimos SSH, HTTP (80) y HTTPS (443)
# (En AWS hay que abrir también estos puertos en el Security Group.)
# -----------------------------------------------------------------------------
ufw allow OpenSSH
ufw allow 'Apache Full'
ufw --force enable

# -----------------------------------------------------------------------------
# Paso 10. Reiniciar los servicios para aplicar los cambios
# -----------------------------------------------------------------------------
systemctl restart "php${PHP_VERSION}-fpm"
systemctl restart apache2
systemctl enable  apache2 mysql "php${PHP_VERSION}-fpm"

set +x
echo
echo "Pila LAMP instalada:"
apache2 -v | head -1
php -v | head -1
mysql --version
echo
echo "Siguiente paso: sudo ./02-setup-letsencrypt.sh"
