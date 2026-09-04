#!/bin/sh

set -e

echo "Waiting for WordPress files..."

while [ ! -f /var/www/html/wp-config.php ]; do
    sleep 2
done

echo "WordPress files are ready."

cd /var/www/html

echo "Waiting for MariaDB..."

until wp db check >/dev/null 2>&1; do
    echo "MariaDB is not ready..."
    sleep 2
done

echo "MariaDB is ready."

if wp core is-installed; then
    echo "WordPress is already installed."
else
    echo "Installing WordPress..."

    wp core install \
        --url="$WORDPRESS_URL" \
        --title="$WORDPRESS_TITLE" \
        --admin_user="$WORDPRESS_ADMIN_USER" \
        --admin_password="$WORDPRESS_ADMIN_PASSWORD" \
        --admin_email="$WORDPRESS_ADMIN_EMAIL" \
        --skip-email

    echo "WordPress installed successfully."
fi
