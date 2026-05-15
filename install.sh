#!/bin/bash
#
# install.sh - Instalador de la suite netmon
#
# Modos:
#   ./install.sh server   - instala SOLO el servidor (datacenter B)
#   ./install.sh client   - instala SOLO los monitores (datacenter A)
#   ./install.sh both     - instala todo (servidor + monitores, mismo host)
#
# Después de instalar, edita /etc/netmon/netmon.conf con la IP del peer
# y arranca con: sudo netmon-ctl start
#
set -e

ROLE="${1:-help}"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: debe ejecutarse como root (usa sudo)"
    exit 1
fi

if ! command -v python3 >/dev/null; then
    echo "ERROR: python3 no está instalado. Instala con:"
    echo "  Debian/Ubuntu: apt install python3"
    echo "  RHEL/Rocky:    dnf install python3"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

show_help() {
    cat <<EOF
Instalador de la suite netmon.

USO:
  sudo ./install.sh <modo>

MODOS:
  server   Instala SOLO el servidor netmon-server.
           Úsalo en el datacenter remoto (B), el que actúa como destino.

  client   Instala SOLO los monitores (latency, microcuts, connections)
           y la herramienta de análisis netmon-report.
           Úsalo en el datacenter A, el que mide.

  both     Instala todo (servidor + monitores). Útil para pruebas
           en un solo host.

DESPUÉS DE INSTALAR:
  1. Edita /etc/netmon/netmon.conf con la IP del peer.
  2. Abre el puerto en el firewall (TCP+UDP 9999 por default).
  3. Arranca: sudo netmon-ctl start
  4. Verifica: sudo netmon-ctl status
  5. Consulta: sudo netmon-ctl report summary --day \$(date -u +%Y-%m-%d)
EOF
}

create_user() {
    # Crear el grupo primero (en RHEL/Rocky, useradd -r no siempre crea el grupo)
    if ! getent group netmon >/dev/null 2>&1; then
        echo "[+] Creando grupo 'netmon'..."
        groupadd -r netmon
    else
        echo "[=] Grupo 'netmon' ya existe"
    fi

    if ! id -u netmon >/dev/null 2>&1; then
        echo "[+] Creando usuario 'netmon'..."
        useradd -r -g netmon -s /sbin/nologin -d /var/log/netmon -M netmon \
            || useradd -r -g netmon -s /bin/false -d /var/log/netmon -M netmon
    else
        echo "[=] Usuario 'netmon' ya existe"
        # Asegurar que pertenece al grupo netmon (por si fue creado antes incorrectamente)
        usermod -g netmon netmon 2>/dev/null || true
    fi
}

create_dirs() {
    echo "[+] Creando directorios..."
    mkdir -p /etc/netmon
    mkdir -p /var/log/netmon/latency
    mkdir -p /var/log/netmon/microcuts
    mkdir -p /var/log/netmon/connections
    chown -R netmon:netmon /var/log/netmon
    chmod 755 /var/log/netmon
}

install_config() {
    if [ ! -f /etc/netmon/netmon.conf ]; then
        echo "[+] Instalando configuración por defecto..."
        cp "$SCRIPT_DIR/netmon.conf.example" /etc/netmon/netmon.conf
        chmod 644 /etc/netmon/netmon.conf
        echo "    ⚠ IMPORTANTE: edita /etc/netmon/netmon.conf con la IP del peer"
    else
        echo "[=] /etc/netmon/netmon.conf ya existe, no se sobreescribe"
    fi
}

install_bins() {
    echo "[+] Instalando ejecutables en /usr/local/bin..."
    for f in netmon-server netmon-latency netmon-microcuts \
             netmon-connections netmon-report netmon-html-report netmon-ctl; do
        if [ -f "$SCRIPT_DIR/bin/$f" ]; then
            cp "$SCRIPT_DIR/bin/$f" /usr/local/bin/
            chmod 755 /usr/local/bin/"$f"
            echo "    /usr/local/bin/$f"
        fi
    done
}

install_systemd() {
    local services=("$@")
    echo "[+] Instalando units de systemd..."
    for svc in "${services[@]}"; do
        cp "$SCRIPT_DIR/systemd/$svc.service" /etc/systemd/system/
        echo "    /etc/systemd/system/$svc.service"
    done
    systemctl daemon-reload
    echo
    echo "[+] Habilitando servicios para arranque automático..."
    for svc in "${services[@]}"; do
        systemctl enable "$svc" 2>&1 | grep -v "Created symlink" || true
        echo "    $svc habilitado"
    done
}

post_install_msg() {
    cat <<EOF

══════════════════════════════════════════════════════════════════
  Instalación completa
══════════════════════════════════════════════════════════════════

PRÓXIMOS PASOS:

  1. Edita la configuración:
       sudo nano /etc/netmon/netmon.conf
     (Pon la IP del datacenter remoto en REMOTE_HOST)

  2. Abre los puertos en el firewall:
       sudo ufw allow 9999/tcp
       sudo ufw allow 9999/udp
     (o con firewalld/iptables, según tu distro)

  3. Prueba la conectividad:
       sudo netmon-ctl test

  4. Arranca los servicios:
       sudo netmon-ctl start
       sudo netmon-ctl status

  5. Consulta los datos (después de algunos minutos):
       sudo netmon-ctl report summary --day \$(date -u +%Y-%m-%d)
       sudo netmon-ctl report hourly  --day \$(date -u +%Y-%m-%d)

Lee LEEME.md para la guía completa.
══════════════════════════════════════════════════════════════════
EOF
}

case "$ROLE" in
    server)
        create_user
        create_dirs
        install_config
        install_bins
        install_systemd netmon-server
        post_install_msg
        ;;
    client)
        create_user
        create_dirs
        install_config
        install_bins
        install_systemd netmon-latency netmon-microcuts netmon-connections
        post_install_msg
        ;;
    both)
        create_user
        create_dirs
        install_config
        install_bins
        install_systemd netmon-server netmon-latency netmon-microcuts netmon-connections
        post_install_msg
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        echo "ERROR: modo desconocido '$ROLE'"
        echo
        show_help
        exit 1
        ;;
esac
