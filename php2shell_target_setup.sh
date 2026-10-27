#!/usr/bin/env bash
# php2shell_target_setup.sh -- run as root on the Ubuntu target (192.168.111.57)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y nginx php-fpm php-cli

PHPV=$(ls -d /etc/php/*/fpm | head -n1 | sed 's|/etc/php/||; s|/fpm||')
echo "[*] using PHP $PHPV ($(php -r 'echo PHP_VERSION;')) -- must be a pre-2026-10-21 (unpatched) build"

# --- exactly one long-lived FPM worker ---------------------------------------
cat > /etc/php/$PHPV/fpm/pool.d/www.conf <<EOF
[www]
user = www-data
group = www-data
listen = /run/php/php${PHPV}-fpm.sock
pm = static
pm.max_children = 1
pm.status_path = /fpm-status
request_terminate_timeout = 0
EOF

# --- lab PHP settings: low ceiling, no input caps ----------------------------
cat > /etc/php/$PHPV/fpm/conf.d/99-lab.ini <<EOF
memory_limit = 128M
post_max_size = 0
upload_max_filesize = 0
max_input_vars = 100000
max_execution_time = 0
display_errors = Off
expose_php = Off
EOF

# --- trivial app (the bug is in the engine, not the app) ---------------------
mkdir -p /var/www/lab
cat > /var/www/lab/index.php <<'EOF'
<?php echo "lab target ok\n";
EOF

# --- nginx: no body cap, stream the body straight to FPM ---------------------
cat > /etc/nginx/sites-available/lab <<EOF
server {
    listen 80 default_server;
    server_name _;
    root /var/www/lab;
    index index.php;
    client_max_body_size 0;
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_request_buffering off;
        fastcgi_read_timeout 300s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/lab /etc/nginx/sites-enabled/lab

# --- deterministic layout (lab cheat; remove for realism) --------------------
sysctl -w kernel.randomize_va_space=0

systemctl restart php${PHPV}-fpm nginx

echo "--- sanity ---"
curl -s http://127.0.0.1/ || true
echo
ps -ef | grep '[p]hp-fpm'
echo "[*] FPM pool workers: $(ps -ef | grep '[p]hp-fpm: pool' | wc -l)  (want 1)"
