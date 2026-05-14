# netmon — Suite de monitoreo de red entre datacenters

Conjunto de herramientas para detectar **latencia, microcortes (al milisegundo), y caídas de conexiones TCP** entre dos servidores Linux ubicados en diferentes datacenters. Diseñado para correr **24/7 como demonio** y permitir análisis histórico de "¿qué pasó el martes a las 3:42 AM?".

---

## Tabla de contenidos

1. [Qué hace y cómo](#qué-hace-y-cómo)
2. [Requisitos](#requisitos)
3. [Instalación](#instalación)
4. [Configuración](#configuración)
5. [Operación diaria](#operación-diaria)
6. [Análisis e investigación de incidentes](#análisis-e-investigación-de-incidentes)
7. [Interpretación de resultados](#interpretación-de-resultados)
8. [Archivos generados](#archivos-generados)
9. [Solución de problemas](#solución-de-problemas)
10. [Tips avanzados](#tips-avanzados)

---

## Qué hace y cómo

La suite consta de **4 componentes** que trabajan en conjunto:

| Componente | Capa medida | Frecuencia | Qué detecta |
|---|---|---|---|
| **netmon-server** | — | continuo | Echo TCP+UDP en el datacenter B (el destino) |
| **netmon-latency** | RTT TCP | 10/seg | Latencia agregada, jitter, percentiles, degradación gradual |
| **netmon-microcuts** | Pérdida UDP | 1000/seg | Microdesconexiones al milisegundo (no las oculta TCP) |
| **netmon-connections** | Conexiones TCP | 1/5seg/conn | Caídas reales de sockets persistentes (lo que sufren tus apps) |
| **netmon-report** | — | bajo demanda | Análisis correlacionado de los 3 monitores |
| **netmon-ctl** | — | bajo demanda | Panel de control único para todo |

**Por qué tres monitores distintos?** Porque miden cosas diferentes:

- Una conexión TCP **puede tener latencia alta** sin caerse → solo `netmon-latency` lo detecta.
- La red **puede tener pérdida del 0.1%** sin afectar TCP visiblemente → solo `netmon-microcuts` (UDP) la ve, porque TCP retransmite y oculta la pérdida.
- Una conexión TCP **puede romperse** sin que haya latencia ni pérdida sostenida (ej. firewall mata sesiones idle) → solo `netmon-connections` lo registra.

Correlacionarlos con `netmon-report` te dice si un incidente fue **real** (varios monitores lo vieron) o **ruido** (solo uno).

---

## Requisitos

- **Sistema operativo**: Linux con systemd (Debian 10+, Ubuntu 18.04+, RHEL/Rocky 8+, Amazon Linux 2+).
- **Python**: 3.7 o superior (sin dependencias externas).
- **Permisos**: root (para crear usuario, instalar servicios y abrir puertos).
- **Conectividad**:
  - Puerto **TCP 9999** abierto entre los dos datacenters (configurable).
  - Puerto **UDP 9999** abierto entre los dos datacenters (configurable).
- **Espacio en disco**: ~5–10 MB/día de logs por host con configuración default.

---

## Instalación

### Paso 1: Copia el paquete a ambos servidores

```bash
# Asumiendo que tienes el directorio netmon-suite/
scp -r netmon-suite/ usuario@servidor-A:/tmp/
scp -r netmon-suite/ usuario@servidor-B:/tmp/
```

### Paso 2: Instala según el rol

En el **datacenter B** (el destino — donde corre `netmon-server`):

```bash
cd /tmp/netmon-suite
sudo bash install.sh server
```

En el **datacenter A** (el medidor — donde corren los monitores):

```bash
cd /tmp/netmon-suite
sudo bash install.sh client
```

Si quieres ambos roles en el mismo host (útil para probar):

```bash
sudo bash install.sh both
```

### Paso 3: Configura la IP del peer

Edita `/etc/netmon/netmon.conf` y pon la IP del **otro** datacenter en `REMOTE_HOST`:

```bash
sudo nano /etc/netmon/netmon.conf
```

```ini
REMOTE_HOST=10.20.30.40      # IP del datacenter B (desde el A)
REMOTE_PORT=9999
```

### Paso 4: Abre el firewall

En el **servidor B** (datacenter destino):

```bash
# UFW (Ubuntu/Debian)
sudo ufw allow 9999/tcp
sudo ufw allow 9999/udp

# firewalld (RHEL/Rocky)
sudo firewall-cmd --permanent --add-port=9999/tcp
sudo firewall-cmd --permanent --add-port=9999/udp
sudo firewall-cmd --reload

# iptables crudo
sudo iptables -A INPUT -p tcp --dport 9999 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 9999 -j ACCEPT
```

⚠ **Tip de seguridad**: limita el acceso por IP origen. Por ejemplo con UFW:

```bash
sudo ufw allow from 10.10.10.10 to any port 9999 proto tcp
sudo ufw allow from 10.10.10.10 to any port 9999 proto udp
```

### Paso 5: Verifica conectividad

En el servidor A:

```bash
sudo netmon-ctl test
```

Debería mostrar:

```
TCP : OK
UDP : OK
Ping: OK (RTT promedio: 12.345ms)
```

### Paso 6: Arranca

En **ambos servidores**:

```bash
sudo netmon-ctl start
sudo netmon-ctl status
```

---

## Configuración

Todo se configura en **`/etc/netmon/netmon.conf`**. Las opciones más importantes:

| Variable | Default | Descripción |
|---|---|---|
| `REMOTE_HOST` | — | **OBLIGATORIO**. IP del peer en el otro DC |
| `REMOTE_PORT` | `9999` | Puerto (TCP y UDP) |
| `LATENCY_INTERVAL` | `0.1` | Segundos entre pings TCP (`0.01` = 100/s para más resolución) |
| `LATENCY_WINDOW` | `10` | Segundos de agregación por ventana CSV |
| `MICROCUTS_RATE` | `1000` | Pings UDP/s. `1000`=res 1ms, `5000`=0.2ms, `10000`=0.1ms |
| `MICROCUTS_BURST_THRESHOLD` | `2` | Paquetes consecutivos perdidos para llamarlo microdesconexión. Sube a `5` o `10` si solo te interesan cortes claros |
| `CONNECTIONS_COUNT` | `4` | Conexiones TCP paralelas. Más = mejor distinguir falla real de ruido |
| `CONNECTIONS_HEARTBEAT_INTERVAL` | `5` | Segundos entre heartbeats de cada conexión |
| `CONNECTIONS_HEARTBEAT_TIMEOUT` | `10` | Cuándo declarar la conexión como "colgada" |

Después de editar la config, recarga los servicios:

```bash
sudo netmon-ctl restart
```

---

## Operación diaria

Todos los comandos pasan por **`netmon-ctl`**:

```bash
sudo netmon-ctl start              # arrancar los 3 monitores
sudo netmon-ctl stop               # detener
sudo netmon-ctl restart            # reiniciar
sudo netmon-ctl status             # estado + resumen de eventos del día
sudo netmon-ctl logs               # últimas 50 líneas de logs operacionales
sudo netmon-ctl logs 200           # últimas 200 líneas
sudo netmon-ctl test               # probar conectividad al peer
```

El comando `status` te da un vistazo rápido:

```
═══════════════════════════════════════════════════════════════════
  netmon-latency             ● ACTIVO desde 2026-05-13 14:32:18
  netmon-microcuts           ● ACTIVO desde 2026-05-13 14:32:19
  netmon-connections         ● ACTIVO desde 2026-05-13 14:32:19
═══════════════════════════════════════════════════════════════════

Configuración actual:
  Host remoto : 10.20.30.40
  Puerto      : 9999
  Logs        : /var/log/netmon/

Eventos hoy (2026-05-14 UTC):
  Microcortes        : 12
  Caídas TCP         : 0
  Stalls TCP         : 0
  Alertas de latencia: 3
```

---

## Análisis e investigación de incidentes

Esta es **la parte más importante**: cómo investigar después.

### Comando 1: Resumen ejecutivo (lo primero que debes correr)

```bash
sudo netmon-ctl report summary --day 2026-05-13
```

Muestra:
- Métricas globales de latencia (p50, p99, peor max)
- Total de microcortes y su distribución (<10ms / 10-100ms / >100ms)
- Caídas/stalls/reconexiones, downtime total y más largo
- **Top 3 incidentes correlacionados** (lo que más importa)

### Comando 2: Vista por hora del día

```bash
sudo netmon-ctl report hourly --day 2026-05-13
```

Te da una tabla así:

```
Hora UTC              p99 med        max   µcuts   cut max  discs  stalls    down
─────────────────────────────────────────────────────────────────────────────────
2026-05-13 02:00       12.50ms     25.10ms      0     0.0ms      0       0     0s
2026-05-13 03:00       45.20ms    250.30ms     17    87.0ms      1       2  15.2s ●
2026-05-13 04:00       12.30ms     22.10ms      0     0.0ms      0       0     0s
```

El círculo `●` rojo te marca las horas problemáticas. Aquí ves claramente que algo pasó a las **03:00 UTC**.

### Comando 3: Timeline detallado de una hora específica

Una vez identificada la hora, pídele el detalle:

```bash
sudo netmon-ctl report timeline --day 2026-05-13 --hour 3
```

```
TIMELINE — 2026-05-13 hora 03:00 UTC
─────────────────────────────────────────────────────────────────
  03:42:15.234  [      MCUT]  87.0ms perdidos (87 paquetes)
  03:42:15.890  [DISCONNECT]  conn=0 error=ConnectionResetError uptime_prev=8742.3s
  03:42:15.891  [DISCONNECT]  conn=1 error=ConnectionResetError uptime_prev=8742.3s
  03:42:15.891  [DISCONNECT]  conn=2 error=ConnectionResetError uptime_prev=8742.3s
  03:42:15.892  [DISCONNECT]  conn=3 error=ConnectionResetError uptime_prev=8742.3s
  03:42:23.105  [ RECONNECT]  conn=0 downtime=7.21s
  ...
```

**Aquí ya tienes el incidente**: a las 03:42:15 hubo un microcorte de 87ms y simultáneamente las 4 conexiones TCP se rompieron con `ConnectionResetError`. Esto es un incidente de red real (no ruido).

### Comando 4: Incidentes correlacionados

```bash
sudo netmon-ctl report incidents --day 2026-05-13 --verbose
```

El analizador automáticamente agrupa eventos cercanos en el tiempo (default: 60 segundos) y les asigna una **severidad**. Si `microcuts + disconnects` ocurren juntos, severidad alta; si solo uno, baja.

### Comando 5: Tops históricos

```bash
# Las 10 microdesconexiones más largas de los últimos 7 días
sudo netmon-ctl report top --by microcuts --limit 10 --start 2026-05-06 --end 2026-05-13

# Los 10 downtimes TCP más largos
sudo netmon-ctl report top --by downtime --limit 10 --start 2026-05-01

# Los 10 picos de latencia
sudo netmon-ctl report top --by latency --limit 10 --day 2026-05-13

# Los 10 incidentes más severos del mes
sudo netmon-ctl report top --by severity --limit 10 --start 2026-05-01 --end 2026-05-31
```

---

## Interpretación de resultados

### Métricas de latencia

| Métrica | Qué significa | Cuándo preocuparse |
|---|---|---|
| **p50 (mediana)** | El RTT típico | Si sube >2× lo habitual → degradación |
| **p99** | El 1% peor | Si supera 5× la mediana → microbursts frecuentes |
| **max** | El peor de la ventana | Si supera 100× la mediana → algo grave puntual |
| **jitter** | Variación entre muestras consecutivas | Alto = malo para VoIP, gaming, trading |
| **stddev** | Variabilidad general | Alto + mean alta = congestión |

### Microcortes UDP

| Duración | Probable causa |
|---|---|
| **2-10ms** | Cola de buffer en switch/router (común, generalmente ignorar) |
| **10-50ms** | Reconfiguración de routing, microcongestion, GC en algún hop |
| **50-500ms** | Failover, link flap, problema real |
| **>500ms** | Caída de enlace o reroute mayor |

⚠ Si tienes **muchos** microcortes de 2-3ms = normalmente normal en redes WAN. Lo importante es la presencia de cortes **largos** y/o **correlacionados con disconnects TCP**.

### Caídas de conexiones TCP

| Error | Significado |
|---|---|
| `ConnectionResetError` / `ECONNRESET` | El peer (o un firewall en medio) envió un RST. Causa común: firewall stateful que cerró la sesión |
| `TimeoutError` (STALL) | Peer dejó de responder pero el socket sigue abierto — típico de redes que se "cuelgan" sin avisar |
| `BrokenPipeError` / `EPIPE` | Tu lado intentó escribir en un socket muerto |
| `ConnectionRefusedError` | El servidor remoto no escucha en el puerto (el server está caído) |
| `EHOSTUNREACH` / `ENETUNREACH` | Routing roto, problema grave |

**Regla de oro**: si las **4 conexiones caen al mismo segundo** = problema de red real. Si solo **1 de 4** = ruido (puede ser un solo path ECMP, un firewall específico, etc.).

---

## Archivos generados

Todos los logs viven bajo **`/var/log/netmon/`**:

```
/var/log/netmon/
├── latency/
│   ├── metrics-YYYY-MM-DD.csv       # Métricas TCP agregadas por ventana
│   ├── events-YYYY-MM-DD.log        # Anomalías de latencia
│   └── latency.log                  # Log operacional
├── microcuts/
│   ├── metrics-YYYY-MM-DD.csv       # Métricas UDP por ventana
│   ├── microcuts-YYYY-MM-DD.log     # Cada microcorte con duración exacta
│   ├── events-YYYY-MM-DD.log        # Eventos importantes
│   └── microcuts.log                # Log operacional
└── connections/
    ├── disconnects-YYYY-MM-DD.log   # Cada caída/reconexión
    ├── uptime-YYYY-MM-DD.csv        # Resumen por hora
    └── connections.log              # Log operacional
```

Los CSV son **importables a Excel, Grafana, pandas**, etc. Ejemplo de procesamiento con AWK:

```bash
# Promedio diario de p99 (columna 8 del CSV de latency)
awk -F, 'NR>1 {sum+=$8; n++} END {print sum/n " µs"}' \
    /var/log/netmon/latency/metrics-2026-05-13.csv

# Top 10 microcortes del día por duración
sort -t= -k4 -n -r /var/log/netmon/microcuts/microcuts-2026-05-13.log | head -10

# Horas con disconnects
awk -F'\t' '/DISCONNECT/ {print substr($1,1,13)}' \
    /var/log/netmon/connections/disconnects-2026-05-13.log | sort | uniq -c
```

### Rotación y retención

Los archivos se **rotan automáticamente por día** (uno por fecha UTC). **No se borran solos**: configura un `cron` o `logrotate` si quieres limitar la retención:

```bash
# Borrar logs CSV/log con más de 90 días (cron diario)
find /var/log/netmon -name "*-20*.csv" -mtime +90 -delete
find /var/log/netmon -name "*-20*.log" -mtime +90 -delete
```

**Tamaño esperado**: ~5–10 MB/día por host con config default.

---

## Solución de problemas

### Los servicios no arrancan

```bash
sudo systemctl status netmon-latency
sudo journalctl -u netmon-latency -n 100
```

Errores comunes:
- **`REMOTE_HOST` vacío**: edita `/etc/netmon/netmon.conf`.
- **Permisos**: `chown -R netmon:netmon /var/log/netmon`.
- **Puerto cerrado**: verifica firewall con `sudo netmon-ctl test`.

### El servidor remoto no responde

```bash
sudo netmon-ctl test
```

Si TCP falla: revisa que `netmon-server` esté corriendo en el datacenter B y que el firewall permita el puerto.

Si UDP falla pero TCP ok: revisa firewall específicamente UDP (algunos solo abren TCP por default).

### Muchos microcortes "fantasma"

Si ves cientos de microcortes pero las apps no notan nada, puede ser **el propio monitor saturando CPU**. Soluciones:

1. Baja `MICROCUTS_RATE` de 1000 a 500.
2. Sube `MICROCUTS_BURST_THRESHOLD` de 2 a 5 o 10.
3. Asigna prioridad: el unit ya tiene `Nice=-5`, pero puedes ir más agresivo con `chrt -f 50`.
4. Verifica drops del kernel:
   ```bash
   cat /proc/net/udp | awk 'NR>1 {sum+=strtonum("0x"$13)} END {print "drops:",sum}'
   ```

### El CSV tiene gaps de minutos

Significa que el servicio se reinició o el log fue rotado. Revisa:

```bash
sudo journalctl -u netmon-microcuts --since "1 hour ago"
```

### Las conexiones TCP se caen constantemente solo 1 de 4

Probablemente un **firewall stateful** está matando una sesión específica (path ECMP determinístico, NAT con timeout corto, etc.). No es problema de la suite — es comportamiento real de la red. Considera reducir `CONNECTIONS_HEARTBEAT_INTERVAL` para mantener sesiones "vivas".

---

## Tips avanzados

### 1. Precisión sub-milisegundo

Para detectar microcortes <1ms:

```ini
MICROCUTS_RATE=10000
```

Esto envía 10K pings/seg (resolución 0.1ms). Asegúrate de que:
- El servidor remoto pueda procesarlos (revisa CPU).
- El kernel tenga buffer UDP grande (ya configurado en el código a 4MB).
- Uses prioridad real-time: edita el `.service` y agrega:
  ```ini
  CPUSchedulingPolicy=fifo
  CPUSchedulingPriority=50
  ```

### 2. Sincronización de relojes

Para correlacionar eventos entre los dos datacenters al milisegundo, los relojes deben estar sincronizados. NTP da ~1-10ms de precisión; **PTP** (Precision Time Protocol) da microsegundos.

```bash
# Verifica sincronización NTP
chronyc tracking          # o: timedatectl status
```

### 3. Exportar a Prometheus/Grafana

Los CSV son fáciles de procesar con `node_exporter` (textfile collector) o un script periódico que parsee el último CSV y exponga métricas. Ejemplo simple:

```bash
# /etc/cron.d/netmon-prometheus
* * * * * netmon awk -F, 'END {print "netmon_p99_us "$8}' /var/log/netmon/latency/metrics-$(date -u +\%Y-\%m-\%d).csv > /var/lib/node_exporter/textfile/netmon.prom
```

### 4. Alertas automáticas

Para enviar alertas cuando hay incidentes serios, puedes correr `netmon-report` periódicamente y revisar la salida:

```bash
# /etc/cron.d/netmon-alert (cada 15 min)
*/15 * * * * root /usr/local/bin/netmon-report --no-color incidents --day $(date -u +\%Y-\%m-\%d) --limit 5 2>&1 | grep "sev=" | mail -s "netmon incidentes" tu@email.com
```

### 5. Bidireccional

Si quieres medir en **ambas direcciones** (A→B y B→A), instala los monitores en los dos hosts apuntándose mutuamente. Esto te permite detectar problemas asimétricos (un sentido funciona y el otro no, lo cual es común con BGP/routing).

### 6. Múltiples destinos

¿Quieres monitorear varios datacenters desde un solo punto? Replica los `.service` con sufijos:

```bash
sudo cp /etc/systemd/system/netmon-microcuts.service /etc/systemd/system/netmon-microcuts-dc2.service
# Edita, cambia REMOTE_HOST y log-dir → /var/log/netmon-dc2/
sudo systemctl enable --now netmon-microcuts-dc2
```

---

## Estructura del paquete

```
netmon-suite/
├── install.sh                          # Instalador
├── netmon.conf.example                 # Config de ejemplo
├── LEEME.md                            # Este archivo
├── bin/
│   ├── netmon-server                   # Servidor TCP+UDP echo
│   ├── netmon-latency                  # Monitor latencia TCP
│   ├── netmon-microcuts                # Monitor microcortes UDP
│   ├── netmon-connections              # Monitor conexiones TCP
│   ├── netmon-report                   # Analizador consolidado
│   └── netmon-ctl                      # Panel de control
└── systemd/
    ├── netmon-server.service
    ├── netmon-latency.service
    ├── netmon-microcuts.service
    └── netmon-connections.service
```

---

## Desinstalación

```bash
sudo netmon-ctl stop
sudo systemctl disable netmon-server netmon-latency netmon-microcuts netmon-connections 2>/dev/null
sudo rm -f /etc/systemd/system/netmon-*.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/netmon-*
sudo rm -rf /etc/netmon
# Opcionalmente, conservar los logs históricos:
# sudo rm -rf /var/log/netmon
sudo userdel netmon
```

---

## Licencia y soporte

Esta es una herramienta interna pensada para diagnóstico de red. Modifícala y adáptala como necesites. Los archivos Python no tienen dependencias externas, lo que facilita el debug y la customización.

**¿Encontraste un bug o tienes una mejora?** Los archivos están comentados y son relativamente cortos: edítalos directamente. Reinicia el servicio afectado con `sudo systemctl restart netmon-XXX` después de cualquier cambio.
