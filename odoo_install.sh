#!/bin/bash

################################################################################
# Script de instalación de Odoo 18 con virtualenv y PostgreSQL
# Compatible con Ubuntu 22.04 y 24.04
# Autor: Linux Server Expert (Updated by Gemini)
################################################################################

set -e

# Variables
ODOO_USER="odoo"
ODOO_HOME="/opt/odoo"
ODOO_REPO="https://www.github.com/odoo/odoo.git"
ODOO_VERSION="18.0"
ODOO_PORT="8069"
ODOO_CONF="/etc/odoo-server.conf"

# Detectar versión de Ubuntu para ajustar Python
UBUNTU_CODENAME=$(lsb_release -cs)
if [ "$UBUNTU_CODENAME" == "noble" ]; then
    PYTHON_VERSION="3.12"
elif [ "$UBUNTU_CODENAME" == "jammy" ]; then
    PYTHON_VERSION="3.10"
else
    # Fallback o dejar que el sistema decida, pero Odoo 18 prefiere 3.10+
    PYTHON_VERSION="3.10"
fi

echo "=== Actualizando sistema ==="
sudo apt update && sudo apt upgrade -y

echo "=== Instalando dependencias base (Python ${PYTHON_VERSION}) ==="
# Se ajusta para usar el python por defecto del sistema si coincide o instalar el especifico
sudo apt install -y git python3 python3-pip python3-venv \
    build-essential wget python3-dev libxml2-dev libxslt1-dev zlib1g-dev \
    libsasl2-dev libldap2-dev libjpeg-dev libpq-dev libffi-dev libtiff-dev \
    libopenjp2-7-dev liblcms2-dev libwebp-dev libharfbuzz-dev libfribidi-dev \
    libxcb1-dev libx11-dev libssl-dev libev-dev npm nodejs fontconfig xfonts-75dpi \
    xfonts-base libxrender1

# Instalar versión específica de python headers si es necesario (generalmente python3-dev cubre el default)
if ! command -v python${PYTHON_VERSION} > /dev/null; then
    sudo apt install -y python${PYTHON_VERSION} python${PYTHON_VERSION}-dev python${PYTHON_VERSION}-venv
fi

echo "=== Instalando Wkhtmltopdf (con patch QT) ==="
# Odoo necesita wkhtmltopdf con parches QT para headers/footers correctos
if ! command -v wkhtmltopdf > /dev/null; then
    WKHTMLTOPDF_VERSION="0.12.6.1-2"
    ARCH=$(dpkg --print-architecture)
    
    if [ "$UBUNTU_CODENAME" == "jammy" ] || [ "$UBUNTU_CODENAME" == "noble" ]; then
        # Usamos el paquete de jammy para noble también por compatibilidad si no hay uno especifico aun, 
        # pero verificamos links. Para script simple, descargamos el de jammy que suele andar.
        # Nota: wkhtmltopdf project is archived, so we use the jammy package.
        wget "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.jammy_${ARCH}.deb" -O /tmp/wkhtmltox.deb
        sudo apt install -y /tmp/wkhtmltox.deb
        rm /tmp/wkhtmltox.deb
    else
        echo ">>> Advertencia: Versión de Ubuntu no optimizada en este script para wkhtmltopdf auto-install."
        echo ">>> Se intentará instalar desde repositorios oficiales (puede no tener parches QT)."
        sudo apt install -y wkhtmltopdf
    fi
else
    echo ">>> Wkhtmltopdf ya instalado."
fi

echo "=== Verificando si PostgreSQL está instalado ==="
if ! command -v psql > /dev/null; then
    echo ">>> PostgreSQL no encontrado. Instalando..."
    sudo apt install -y postgresql
    sudo systemctl enable postgresql
    sudo systemctl start postgresql
else
    echo ">>> PostgreSQL ya está instalado. Continuando..."
fi

echo "=== Creando usuario de PostgreSQL para Odoo ==="
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ODOO_USER}'" | grep -q 1; then
    sudo -u postgres createuser -s ${ODOO_USER}
    echo ">>> Usuario '${ODOO_USER}' creado en PostgreSQL"
else
    echo ">>> Usuario '${ODOO_USER}' ya existe en PostgreSQL"
fi

echo "=== Creando usuario del sistema para Odoo ==="
if ! id -u ${ODOO_USER} > /dev/null 2>&1; then
    sudo adduser --system --quiet --shell=/bin/bash --home=${ODOO_HOME} --group ${ODOO_USER}
    echo ">>> Usuario del sistema '${ODOO_USER}' creado"
else
    echo ">>> Usuario del sistema '${ODOO_USER}' ya existe"
fi

echo "=== Clonando código de Odoo ==="
if [ ! -d "${ODOO_HOME}/src" ]; then
    # Crear directorio padre si no existe
    sudo mkdir -p ${ODOO_HOME}
    sudo chown ${ODOO_USER}:${ODOO_USER} ${ODOO_HOME}
    
    sudo -u ${ODOO_USER} git clone --depth=1 --branch ${ODOO_VERSION} ${ODOO_REPO} ${ODOO_HOME}/src
else
    echo ">>> Código de Odoo ya existe en ${ODOO_HOME}/src"
fi

echo "=== Creando entorno virtual Python ==="
if [ ! -d "${ODOO_HOME}/venv" ]; then
    sudo -u ${ODOO_USER} python${PYTHON_VERSION} -m venv ${ODOO_HOME}/venv
    sudo -u ${ODOO_USER} ${ODOO_HOME}/venv/bin/pip install -U pip setuptools wheel
    echo ">>> Entorno virtual creado con Python ${PYTHON_VERSION}"
else
    echo ">>> Entorno virtual ya existe"
fi

echo "=== Instalando dependencias de Odoo ==="
# Instalar psycopg2-binary o compilar psycopg2 (libpq-dev requerido, ya instalado)
# requirements.txt de Odoo suele tener psycopg2 puro.
# Pre-instalar gevent para asegurar uso de wheel binario o build correcto antes de requirements
sudo -u ${ODOO_USER} ${ODOO_HOME}/venv/bin/pip install gevent
sudo -u ${ODOO_USER} ${ODOO_HOME}/venv/bin/pip install -r ${ODOO_HOME}/src/requirements.txt

echo "=== Creando archivo de configuración de Odoo ==="
sudo tee ${ODOO_CONF} > /dev/null <<EOF
[options]
admin_passwd = admin
db_host = False
db_port = False
db_user = ${ODOO_USER}
db_password = False
addons_path = ${ODOO_HOME}/src/addons
logfile = /var/log/odoo/odoo.log
xmlrpc_port = ${ODOO_PORT}
EOF

sudo chown ${ODOO_USER}:${ODOO_USER} ${ODOO_CONF}
sudo chmod 640 ${ODOO_CONF}

echo "=== Creando carpeta de logs ==="
sudo mkdir -p /var/log/odoo
sudo chown ${ODOO_USER}:${ODOO_USER} /var/log/odoo

echo "=== Creando servicio systemd para Odoo ==="
sudo tee /etc/systemd/system/odoo.service > /dev/null <<EOF
[Unit]
Description=Odoo ERP ${ODOO_VERSION}
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_USER}
WorkingDirectory=${ODOO_HOME}/src
ExecStart=${ODOO_HOME}/venv/bin/python3 ${ODOO_HOME}/src/odoo-bin -c ${ODOO_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
StandardOutput=journal+console
StandardError=journal+console
SyslogIdentifier=odoo
Restart=on-failure
RestartSec=5s
TimeoutSec=300

[Install]
WantedBy=multi-user.target
EOF

echo "=== Habilitando y arrancando Odoo ==="
sudo systemctl daemon-reload
sudo systemctl enable odoo
sudo systemctl restart odoo

echo "=== Instalación completa ==="
echo "Accede a Odoo en: http://<IP-SERVIDOR>:${ODOO_PORT}"
echo "Logs: sudo journalctl -u odoo -f"
