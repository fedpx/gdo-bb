#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Глобальные переменные для отслеживания установленных компонентов
INSTALLED_PACKAGES=()
CREATED_FILES=()
ENABLED_SERVICES=()
INSTALLATION_LOG="/tmp/lamp_install.log"
CLEANUP_REQUIRED=false

# Проверка на root-доступ
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Ошибка: Этот скрипт должен быть запущен с правами root${NC}"
  exit 1
fi

# Создание лог-файла
echo "=== LAMP/LEMP Installation Log ===" > "$INSTALLATION_LOG"
echo "Start time: $(date)" >> "$INSTALLATION_LOG"

# Функция логирования
log_action() {
  local action="$1"
  local details="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $action: $details" >> "$INSTALLATION_LOG"
  echo -e "${YELLOW}[LOG]${NC} $action: $details"
}

# Функция cleanup для отката изменений
cleanup() {
  if [ "$CLEANUP_REQUIRED" = true ]; then
    echo -e "\n${RED}Прерывание установки. Выполняется откат изменений...${NC}"
    log_action "CLEANUP" "Starting cleanup process"
    
    # Останавливаем и отключаем сервисы
    for service in "${ENABLED_SERVICES[@]}"; do
      echo -e "${YELLOW}Останавливаем сервис: $service${NC}"
      systemctl stop "$service" 2>/dev/null || true
      systemctl disable "$service" 2>/dev/null || true
      log_action "CLEANUP" "Stopped and disabled service: $service"
    done
    
    # Удаляем созданные файлы
    for file in "${CREATED_FILES[@]}"; do
      if [ -f "$file" ] || [ -d "$file" ]; then
        echo -e "${YELLOW}Удаляем файл/директорию: $file${NC}"
        rm -rf "$file" 2>/dev/null || true
        log_action "CLEANUP" "Removed file/directory: $file"
      fi
    done
    
    # Удаляем установленные пакеты
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
      echo -e "${YELLOW}Удаляем установленные пакеты...${NC}"
      
      if [ "$PKG_MANAGER" = "apt-get" ]; then
        for package in "${INSTALLED_PACKAGES[@]}"; do
          $PKG_MANAGER remove --purge -y "$package" 2>/dev/null || true
          log_action "CLEANUP" "Removed package: $package"
        done
        $PKG_MANAGER autoremove -y 2>/dev/null || true
        $PKG_MANAGER autoclean 2>/dev/null || true
      else
        for package in "${INSTALLED_PACKAGES[@]}"; do
          $PKG_MANAGER remove -y "$package" 2>/dev/null || true
          log_action "CLEANUP" "Removed package: $package"
        done
      fi
    fi
    
    # Восстанавливаем конфигурации фаервола
    echo -e "${YELLOW}Восстанавливаем настройки фаервола...${NC}"
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
      if command -v ufw >/dev/null 2>&1; then
        ufw delete allow http 2>/dev/null || true
        ufw delete allow https 2>/dev/null || true
        log_action "CLEANUP" "Removed UFW rules"
      fi
    else
      if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-service=http 2>/dev/null || true
        firewall-cmd --permanent --remove-service=https 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_action "CLEANUP" "Removed firewalld rules"
      fi
    fi
    
    # Удаляем пользователей и базы данных MySQL
    if command -v mysql >/dev/null 2>&1 && [ -n "$DB_ROOT_PASSWORD" ]; then
      echo -e "${YELLOW}Очищаем тестовые данные MySQL...${NC}"
      mysql -u root -p"${DB_ROOT_PASSWORD}" 2>/dev/null <<EOF || true
DROP DATABASE IF EXISTS test_db;
DROP USER IF EXISTS 'test_user'@'localhost';
FLUSH PRIVILEGES;
EOF
      log_action "CLEANUP" "Removed test database and user"
    fi
    
    echo -e "${GREEN}Откат изменений завершен${NC}"
    echo -e "${YELLOW}Лог операций сохранен в: $INSTALLATION_LOG${NC}"
    log_action "CLEANUP" "Cleanup completed"
  else
    echo -e "\n${YELLOW}Скрипт прерван до начала установки${NC}"
  fi
  
  exit 1
}

# Установка обработчиков сигналов
trap cleanup SIGINT SIGTERM SIGHUP SIGQUIT

# Функция для добавления пакета в список установленных
add_installed_package() {
  local package="$1"
  INSTALLED_PACKAGES+=("$package")
  log_action "INSTALL" "Package added to tracking: $package"
}

# Функция для добавления файла в список созданных
add_created_file() {
  local file="$1"
  CREATED_FILES+=("$file")
  log_action "CREATE" "File added to tracking: $file"
}

# Функция для добавления сервиса в список включенных
add_enabled_service() {
  local service="$1"
  ENABLED_SERVICES+=("$service")
  log_action "SERVICE" "Service added to tracking: $service"
}

# Определение версии Apache
get_apache_version() {
  if [ "$PKG_MANAGER" = "apt-get" ]; then
    APACHE_SERVICE="apache2"
  else
    APACHE_SERVICE="httpd"
  fi
}

# Определение версии MariaDB/MySQL
get_mariadb_version() {
  if command -v mysql >/dev/null 2>&1; then
    MYSQL_VERSION=$(mysql --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
  else
    MYSQL_VERSION="10.5" # fallback
  fi
  MYSQL_SERVICE="mariadb"
}

# Определение дистрибутива и пакетного менеджера
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
  elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    OS_VERSION=$(lsb_release -sr)
  else
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    OS_VERSION=$(uname -r)
  fi

  case $OS in
    ubuntu|debian)
      PKG_MANAGER="apt-get"
      INSTALL_CMD="install -y"
      ;;
    centos|rhel|fedora|rocky|almalinux)
      # Проверяем версию для выбора пакетного менеджера
      if [ "$OS" = "centos" ] && [ "${OS_VERSION%%.*}" -lt 8 ]; then
        PKG_MANAGER="yum"
      else
        PKG_MANAGER="dnf"
      fi
      INSTALL_CMD="install -y"
      ;;
    *)
      echo -e "${RED}Неизвестный дистрибутив Linux: $OS${NC}"
      exit 1
      ;;
  esac
  
  # Инициализируем версии сервисов
  get_apache_version
  get_mariadb_version
}

# Установка необходимых пакетов
install_packages() {
  echo -e "${YELLOW}Обновление списка пакетов...${NC}"
  CLEANUP_REQUIRED=true
  
  # Для Debian/Ubuntu
  if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    $PKG_MANAGER update -y
    log_action "UPDATE" "Package list updated (apt-get)"
    
    local packages=("software-properties-common" "curl" "wget" "unzip" "expect")
    for package in "${packages[@]}"; do
      echo -e "${YELLOW}Устанавливаем: $package${NC}"
      if $PKG_MANAGER $INSTALL_CMD "$package"; then
        add_installed_package "$package"
      else
        echo -e "${RED}Ошибка установки пакета: $package${NC}"
        cleanup
      fi
    done
  else
    # Для RHEL/CentOS/Fedora
    $PKG_MANAGER update -y
    log_action "UPDATE" "Package list updated ($PKG_MANAGER)"
    
    # Проверяем, нужен ли EPEL
    if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "rocky" ] || [ "$OS" = "almalinux" ]; then
      echo -e "${YELLOW}Устанавливаем: epel-release${NC}"
      if $PKG_MANAGER $INSTALL_CMD epel-release; then
        add_installed_package "epel-release"
      else
        echo -e "${RED}Ошибка установки EPEL${NC}"
        cleanup
      fi
    fi
    
    local packages=("curl" "wget" "unzip" "expect")
    for package in "${packages[@]}"; do
      echo -e "${YELLOW}Устанавливаем: $package${NC}"
      if $PKG_MANAGER $INSTALL_CMD "$package"; then
        add_installed_package "$package"
      else
        echo -e "${RED}Ошибка установки пакета: $package${NC}"
        cleanup
      fi
    done
  fi
}

# Установка веб-сервера (Apache или Nginx)
install_webserver() {
  while true; do
    read -p "Выберите веб-сервер: [1] Apache [2] Nginx (по умолчанию: 1): " webserver_choice
    
    case $webserver_choice in
      2)
        echo -e "${YELLOW}Установка Nginx...${NC}"
        if $PKG_MANAGER $INSTALL_CMD nginx; then
          add_installed_package "nginx"
          
          systemctl enable nginx
          add_enabled_service "nginx"
          
          systemctl start nginx
          
          if ! systemctl is-active --quiet nginx; then
            echo -e "${RED}Ошибка: Nginx не запустился${NC}"
            cleanup
          fi
          
          WEBSERVER="nginx"
          log_action "INSTALL" "Nginx installed and started successfully"
          break
        else
          echo -e "${RED}Ошибка установки Nginx${NC}"
          cleanup
        fi
        ;;
      1|"")
        echo -e "${YELLOW}Установка Apache...${NC}"
        if [ "$PKG_MANAGER" = "apt-get" ]; then
          if $PKG_MANAGER $INSTALL_CMD apache2; then
            add_installed_package "apache2"
            
            systemctl enable "$APACHE_SERVICE"
            add_enabled_service "$APACHE_SERVICE"
            
            systemctl start "$APACHE_SERVICE"
            
            if ! systemctl is-active --quiet "$APACHE_SERVICE"; then
              echo -e "${RED}Ошибка: Apache не запустился${NC}"
              cleanup
            fi
          else
            echo -e "${RED}Ошибка установки Apache${NC}"
            cleanup
          fi
        else
          if $PKG_MANAGER $INSTALL_CMD httpd; then
            add_installed_package "httpd"
            
            systemctl enable "$APACHE_SERVICE"
            add_enabled_service "$APACHE_SERVICE"
            
            systemctl start "$APACHE_SERVICE"
            
            if ! systemctl is-active --quiet "$APACHE_SERVICE"; then
              echo -e "${RED}Ошибка: Apache не запустился${NC}"
              cleanup
            fi
          else
            echo -e "${RED}Ошибка установки Apache${NC}"
            cleanup
          fi
        fi
        WEBSERVER="apache"
        log_action "INSTALL" "Apache installed and started successfully"
        break
        ;;
      *)
        echo -e "${RED}Неверный выбор. Введите 1 или 2${NC}"
        ;;
    esac
  done
}

# Определение версии PHP
get_php_version() {
  if command -v php >/dev/null 2>&1; then
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
  else
    # Для Ubuntu/Debian по умолчанию используем последнюю доступную версию
    if [ "$PKG_MANAGER" = "apt-get" ]; then
      # Определяем доступные версии PHP в репозитории
      local available_versions=$(apt-cache search "^php[0-9]\.[0-9]$" | grep -oE "php[0-9]\.[0-9]" | sort -V | tail -1)
      if [ -n "$available_versions" ]; then
        PHP_VERSION=$(echo "$available_versions" | sed 's/php//')
      else
        PHP_VERSION="8.1" # fallback для Ubuntu
      fi
    else
      PHP_VERSION="8.1" # fallback для RHEL/CentOS
    fi
  fi
  echo -e "${GREEN}Определена версия PHP: ${YELLOW}$PHP_VERSION${NC}"
}

# Установка PHP
install_php() {
  echo -e "${YELLOW}Установка PHP...${NC}"
  
  get_php_version
  
  if [ "$PKG_MANAGER" = "apt-get" ]; then
    # Для Ubuntu/Debian устанавливаем конкретную версию
    local php_packages=("php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip")
    
    for package in "${php_packages[@]}"; do
      echo -e "${YELLOW}Устанавливаем: $package${NC}"
      if $PKG_MANAGER $INSTALL_CMD "$package"; then
        add_installed_package "$package"
      else
        echo -e "${RED}Ошибка установки пакета: $package${NC}"
        cleanup
      fi
    done
    
    # Определяем имя сервиса PHP-FPM
    PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
  else
    # Для RHEL/CentOS/Fedora обычно используется общее имя
    local php_packages=("php" "php-cli" "php-fpm" "php-mysqlnd" "php-curl" "php-gd" "php-mbstring" "php-xml" "php-zip")
    
    for package in "${php_packages[@]}"; do
      echo -e "${YELLOW}Устанавливаем: $package${NC}"
      if $PKG_MANAGER $INSTALL_CMD "$package"; then
        add_installed_package "$package"
      else
        echo -e "${RED}Ошибка установки пакета: $package${NC}"
        cleanup
      fi
    done
    
    # Определяем имя сервиса PHP-FPM
    PHP_FPM_SERVICE="php-fpm"
  fi
  
  # Проверяем и запускаем PHP-FPM
  if systemctl list-unit-files | grep -q "$PHP_FPM_SERVICE"; then
    systemctl enable "$PHP_FPM_SERVICE"
    add_enabled_service "$PHP_FPM_SERVICE"
    
    systemctl start "$PHP_FPM_SERVICE"
    
    if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
      echo -e "${GREEN}$PHP_FPM_SERVICE запущен успешно${NC}"
      log_action "INSTALL" "$PHP_FPM_SERVICE installed and started successfully"
    else
      echo -e "${RED}Ошибка: $PHP_FPM_SERVICE не запустился${NC}"
      cleanup
    fi
  else
    echo -e "${YELLOW}$PHP_FPM_SERVICE не найден, PHP-FPM может не требоваться для Apache${NC}"
  fi
}

# Установка MySQL/MariaDB
install_database() {
  echo -e "${YELLOW}Установка MariaDB...${NC}"
  
  if [ "$PKG_MANAGER" = "apt-get" ]; then
    local db_packages=("mariadb-server" "mariadb-client")
    for package in "${db_packages[@]}"; do
      echo -e "${YELLOW}Устанавливаем: $package${NC}"
      if $PKG_MANAGER $INSTALL_CMD "$package"; then
        add_installed_package "$package"
      else
        echo -e "${RED}Ошибка установки пакета: $package${NC}"
        cleanup
      fi
    done
  else
    local db_packages=("mariadb-server" "mariadb")
    for package in "${db_packages[@]}"; do
      echo -e "${YELLOW}Устанавливаем: $package${NC}"
      if $PKG_MANAGER $INSTALL_CMD "$package"; then
        add_installed_package "$package"
      else
        echo -e "${RED}Ошибка установки пакета: $package${NC}"
        cleanup
      fi
    done
  fi
  
  systemctl enable "$MYSQL_SERVICE"
  add_enabled_service "$MYSQL_SERVICE"
  
  systemctl start "$MYSQL_SERVICE"
  
  if ! systemctl is-active --quiet "$MYSQL_SERVICE"; then
    echo -e "${RED}Ошибка: MariaDB не запустился${NC}"
    cleanup
  fi
  
  log_action "INSTALL" "MariaDB installed and started successfully"
  
  # Настройка безопасности MySQL с использованием expect
  echo -e "${YELLOW}Настройка безопасности MySQL...${NC}"
  
  # Используем expect для автоматизации mysql_secure_installation
  if ! expect -c "
    spawn mysql_secure_installation
    expect \"Enter current password for root (enter for none):\"
    send \"\\r\"
    expect \"Set root password?\"
    send \"y\\r\"
    expect \"New password:\"
    send \"${DB_ROOT_PASSWORD}\\r\"
    expect \"Re-enter new password:\"
    send \"${DB_ROOT_PASSWORD}\\r\"
    expect \"Remove anonymous users?\"
    send \"y\\r\"
    expect \"Disallow root login remotely?\"
    send \"y\\r\"
    expect \"Remove test database and access to it?\"
    send \"y\\r\"
    expect \"Reload privilege tables now?\"
    send \"y\\r\"
    expect eof
  "; then
    echo -e "${RED}Ошибка настройки безопасности MySQL${NC}"
    cleanup
  fi
  
  log_action "CONFIGURE" "MySQL security configuration completed"
}

# Создание тестовой базы данных
create_test_db() {
  echo -e "${YELLOW}Создание тестовой базы данных...${NC}"
  
  # Создаем временный файл с SQL командами
  local sql_file="/tmp/create_db.sql"
  cat > "$sql_file" <<EOF
CREATE DATABASE IF NOT EXISTS test_db;
CREATE USER IF NOT EXISTS 'test_user'@'localhost' IDENTIFIED BY 'test_password';
GRANT ALL PRIVILEGES ON test_db.* TO 'test_user'@'localhost';
FLUSH PRIVILEGES;
EOF
  
  # Выполняем SQL команды
  mysql -u root -p"${DB_ROOT_PASSWORD}" < "$sql_file"
  
  # Удаляем временный файл
  rm -f "$sql_file"
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Тестовая база данных создана:${NC}"
    echo -e "Имя базы: ${YELLOW}test_db${NC}"
    echo -e "Пользователь: ${YELLOW}test_user${NC}"
    echo -e "Пароль: ${YELLOW}test_password${NC}"
    log_action "CREATE" "Test database and user created successfully"
  else
    echo -e "${RED}Ошибка создания тестовой базы данных${NC}"
    cleanup
  fi
}

# Настройка SELinux для веб-сервера (только для RHEL/CentOS)
configure_selinux() {
  if [ "$PKG_MANAGER" != "apt-get" ]; then
    echo -e "${YELLOW}Проверка и настройка SELinux...${NC}"
    
    if command -v getenforce >/dev/null 2>&1; then
      SELINUX_STATUS=$(getenforce)
      if [ "$SELINUX_STATUS" = "Enforcing" ]; then
        echo -e "${YELLOW}SELinux включен, настраиваем политики...${NC}"
        
        # Устанавливаем необходимые инструменты SELinux
        $PKG_MANAGER $INSTALL_CMD policycoreutils-python-utils 2>/dev/null || \
        $PKG_MANAGER $INSTALL_CMD policycoreutils-python 2>/dev/null || true
        
        # Разрешаем httpd подключаться к сети
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
        
        # Устанавливаем правильные контексты для веб-директории
        if [ "$WEBSERVER" = "apache" ]; then
          semanage fcontext -a -t httpd_exec_t "/var/www/html(/.*)?" 2>/dev/null || true
          restorecon -R /var/www/html 2>/dev/null || true
        fi
        
        echo -e "${GREEN}SELinux настроен${NC}"
        log_action "CONFIGURE" "SELinux configured successfully"
      else
        echo -e "${YELLOW}SELinux отключен или в режиме Permissive${NC}"
      fi
    else
      echo -e "${YELLOW}SELinux не найден${NC}"
    fi
  fi
}

# Настройка фаервола
configure_firewall() {
  echo -e "${YELLOW}Настройка фаервола...${NC}"
  
  if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    if command -v ufw >/dev/null 2>&1; then
      ufw allow ssh
      ufw allow http
      ufw allow https
      ufw --force enable
      echo -e "${GREEN}UFW настроен${NC}"
      log_action "CONFIGURE" "UFW firewall configured"
    else
      echo -e "${YELLOW}UFW не найден, пропускаем настройку фаервола${NC}"
    fi
  else
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --add-service=ssh
      firewall-cmd --permanent --add-service=http
      firewall-cmd --permanent --add-service=https
      firewall-cmd --reload
      echo -e "${GREEN}Firewalld настроен${NC}"
      log_action "CONFIGURE" "Firewalld configured"
    else
      echo -e "${YELLOW}Firewalld не найден, пропускаем настройку фаервола${NC}"
    fi
  fi
  
  # Настройка SELinux после фаервола
  configure_selinux
}

# Настройка Nginx для работы с PHP-FPM
configure_nginx_php() {
  echo -e "${YELLOW}Настройка Nginx для работы с PHP-FPM...${NC}"
  
  # Определяем путь к конфигурации Nginx
  if [ "$PKG_MANAGER" = "apt-get" ]; then
    NGINX_CONF="/etc/nginx/sites-available/default"
    NGINX_CONF_DIR="/etc/nginx/sites-available"
  else
    NGINX_CONF="/etc/nginx/nginx.conf"
    NGINX_CONF_DIR="/etc/nginx/conf.d"
  fi
  
  # Создаем резервную копию оригинальной конфигурации
  if [ -f "$NGINX_CONF" ]; then
    cp "$NGINX_CONF" "${NGINX_CONF}.backup"
    add_created_file "${NGINX_CONF}.backup"
  fi
  
  # Создаем базовую конфигурацию для PHP
  if [ "$PKG_MANAGER" = "apt-get" ]; then
    # Для Ubuntu/Debian создаем конфигурацию с учетом версии PHP
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.php index.html index.htm;

    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    add_created_file "$NGINX_CONF"
  else
    # Для RHEL/CentOS создаем конфигурацию в conf.d
    local nginx_conf_file="${NGINX_CONF_DIR}/default.conf"
    cat > "$nginx_conf_file" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /usr/share/nginx/html;
    index index.php index.html index.htm;

    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    add_created_file "$nginx_conf_file"
  fi
  
  log_action "CONFIGURE" "Nginx configuration created successfully"
}

# Настройка Apache для работы с PHP
configure_apache_php() {
  echo -e "${YELLOW}Настройка Apache для работы с PHP...${NC}"
  
  if [ "$PKG_MANAGER" = "apt-get" ]; then
    # Для Ubuntu/Debian включаем модуль PHP
    if a2enmod php${PHP_VERSION}; then
      log_action "CONFIGURE" "Apache PHP${PHP_VERSION} module enabled"
    else
      echo -e "${RED}Ошибка включения модуля PHP${PHP_VERSION}${NC}"
      cleanup
    fi
    
    if a2enmod rewrite; then
      log_action "CONFIGURE" "Apache rewrite module enabled"
    else
      echo -e "${RED}Ошибка включения модуля rewrite${NC}"
      cleanup
    fi
    
    if systemctl restart apache2; then
      log_action "CONFIGURE" "Apache restarted successfully"
    else
      echo -e "${RED}Ошибка перезапуска Apache${NC}"
      cleanup
    fi
  else
    # Для RHEL/CentOS просто перезапускаем
    if systemctl restart httpd; then
      log_action "CONFIGURE" "Apache (httpd) restarted successfully"
    else
      echo -e "${RED}Ошибка перезапуска Apache${NC}"
      cleanup
    fi
  fi
}

# Создание тестового PHP файла
create_test_php() {
  echo -e "${YELLOW}Создание тестового PHP файла...${NC}"
  
  # Определяем путь к веб-директории
  if [ "$WEBSERVER" = "apache" ]; then
    if [ "$PKG_MANAGER" = "apt-get" ]; then
      WEB_DIR="/var/www/html"
    else
      WEB_DIR="/var/www/html"
    fi
  else
    if [ "$PKG_MANAGER" = "apt-get" ]; then
      WEB_DIR="/var/www/html"
    else
      WEB_DIR="/usr/share/nginx/html"
    fi
  fi
  
  # Создаем info.php
  local info_php="${WEB_DIR}/info.php"
  cat > "$info_php" <<EOF
<?php
phpinfo();
?>
EOF
  add_created_file "$info_php"
  
  # Создаем простой тест подключения к БД
  local db_test_php="${WEB_DIR}/db_test.php"
  cat > "$db_test_php" <<EOF
<?php
\$host = 'localhost';
\$dbname = 'test_db';
\$username = 'test_user';
\$password = 'test_password';

try {
    \$pdo = new PDO("mysql:host=\$host;dbname=\$dbname", \$username, \$password);
    echo "<h2>Подключение к базе данных успешно!</h2>";
    echo "<p>Версия MySQL: " . \$pdo->getAttribute(PDO::ATTR_SERVER_VERSION) . "</p>";
} catch(PDOException \$e) {
    echo "<h2>Ошибка подключения к базе данных:</h2>";
    echo "<p>" . \$e->getMessage() . "</p>";
}
?>
EOF
  add_created_file "$db_test_php"
  
  # Устанавливаем правильные права
  chown -R www-data:www-data "${WEB_DIR}" 2>/dev/null || chown -R apache:apache "${WEB_DIR}" 2>/dev/null || true
  chmod -R 755 "${WEB_DIR}"
  
  log_action "CREATE" "Test PHP files created successfully"
}

# Основная функция
main() {
  echo -e "${GREEN}=== Автоматическая установка LAMP/LEMP стека ===${NC}"
  
  detect_os
  echo -e "${GREEN}Обнаружена система: ${YELLOW}$OS $OS_VERSION${NC}"
  echo -e "${GREEN}Используется пакетный менеджер: ${YELLOW}$PKG_MANAGER${NC}"
  
  # Генерация пароля для root MySQL
  DB_ROOT_PASSWORD=$(openssl rand -base64 12)
  echo -e "${YELLOW}Пароль root для MySQL: ${RED}$DB_ROOT_PASSWORD${NC}"
  echo -e "${YELLOW}Сохраните этот пароль!${NC}"
  
  # Запись пароля в файл
  local credentials_file="/root/mysql_credentials.txt"
  echo "MySQL Root Password: $DB_ROOT_PASSWORD" > "$credentials_file"
  echo "Test DB User: test_user" >> "$credentials_file"
  echo "Test DB Password: test_password" >> "$credentials_file"
  chmod 600 "$credentials_file"
  add_created_file "$credentials_file"
  
  echo -e "${YELLOW}Начинаем установку...${NC}"
  
  install_packages
  install_webserver
  install_php
  install_database
  create_test_db
  configure_firewall
  create_test_php
  
  # Настройка веб-сервера для работы с PHP
  if [ "$WEBSERVER" = "apache" ]; then
    configure_apache_php
  else
    configure_nginx_php
    if systemctl restart nginx; then
      log_action "CONFIGURE" "Nginx restarted successfully"
    else
      echo -e "${RED}Ошибка перезапуска Nginx${NC}"
      cleanup
    fi
    
    if [ -n "$PHP_FPM_SERVICE" ] && systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
      if systemctl restart "$PHP_FPM_SERVICE"; then
        log_action "CONFIGURE" "$PHP_FPM_SERVICE restarted successfully"
      else
        echo -e "${RED}Ошибка перезапуска $PHP_FPM_SERVICE${NC}"
        cleanup
      fi
    fi
  fi
  
  echo -e "${GREEN}=================================${NC}"
  echo -e "${GREEN}Установка завершена успешно!${NC}"
  echo -e "${GREEN}=================================${NC}"
  
  # Финальная проверка состояния сервисов
  echo -e "${YELLOW}Проверка состояния сервисов:${NC}"
  
  # Проверяем веб-сервер
  if [ "$WEBSERVER" = "apache" ]; then
    if systemctl is-active --quiet "$APACHE_SERVICE"; then
      echo -e "${GREEN}✓ Apache работает${NC}"
    else
      echo -e "${RED}✗ Apache не работает${NC}"
    fi
  else
    if systemctl is-active --quiet nginx; then
      echo -e "${GREEN}✓ Nginx работает${NC}"
    else
      echo -e "${RED}✗ Nginx не работает${NC}"
    fi
  fi
  
  # Проверяем PHP-FPM (если установлен)
  if [ -n "$PHP_FPM_SERVICE" ] && systemctl list-unit-files | grep -q "$PHP_FPM_SERVICE"; then
    if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
      echo -e "${GREEN}✓ $PHP_FPM_SERVICE работает${NC}"
    else
      echo -e "${RED}✗ $PHP_FPM_SERVICE не работает${NC}"
    fi
  fi
  
  # Проверяем MariaDB
  if systemctl is-active --quiet "$MYSQL_SERVICE"; then
    echo -e "${GREEN}✓ MariaDB работает${NC}"
  else
    echo -e "${RED}✗ MariaDB не работает${NC}"
  fi
  
  echo -e "${YELLOW}Проверьте работу системы:${NC}"
  echo -e "Главная страница: ${YELLOW}http://$(hostname -I | awk '{print $1}')${NC}"
  echo -e "PHP Info: ${YELLOW}http://$(hostname -I | awk '{print $1}')/info.php${NC}"
  echo -e "Тест БД: ${YELLOW}http://$(hostname -I | awk '{print $1}')/db_test.php${NC}"
  
  echo -e "${YELLOW}Учетные данные MySQL:${NC}"
  echo -e "Root пароль: ${RED}$DB_ROOT_PASSWORD${NC}"
  echo -e "Тест БД - База: ${YELLOW}test_db${NC}"
  echo -e "Тест БД - Пользователь: ${YELLOW}test_user${NC}"
  echo -e "Тест БД - Пароль: ${YELLOW}test_password${NC}"
  
  echo -e "${GREEN}Пароли сохранены в файле: ${YELLOW}$credentials_file${NC}"
  
  echo -e "${YELLOW}Для безопасности рекомендуется удалить файл info.php после тестирования${NC}"
  echo -e "${YELLOW}Лог установки сохранен в: ${GREEN}$INSTALLATION_LOG${NC}"
  
  # Установка завершена успешно, больше не нужен cleanup при прерывании
  CLEANUP_REQUIRED=false
  
  log_action "SUCCESS" "LAMP/LEMP installation completed successfully"
  echo "End time: $(date)" >> "$INSTALLATION_LOG"
  echo "Installation completed successfully" >> "$INSTALLATION_LOG"
}

# Запуск основной функции
main "$@"