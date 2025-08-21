## **1. Установка LEMP (Nginx + MySQL/MariaDB + PHP)**
### 1.1 Установка всех необходимых пакетов
```
# Установка Nginx
sudo apt update && sudo apt install nginx -y
sudo systemctl start nginx
sudo systemctl enable nginx

Установка PHP
sudo apt install php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip -y
sudo systemctl start php8.3-fpm
sudo systemctl enable php8.3-fpm

# Установка MariaDB
sudo apt install mariadb-server mariadb-client -y
sudo mysql_secure_installation
# (Нужно задать пароль для root и ответить `Y` на все вопросы безопасности.)
sudo systemctl start mariadb
sudo systemctl enable mariadb
```
### 1.2 Настройка Nginx и проверка работы PHP
Открываем конфиг:
```
sudo vim /etc/nginx/sites-available/default
```
Находим блок `server` и добавляем значение `index.php`:
```
index index.php index.html index.htm;
```
Добавляем в блок `location` обработку PHP:
Посмотрите файл, возможно в нем уже есть нужные строки и их надо будет просто раскомментировать и поменять версию php на вашу:
```
location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
}
```
Проверяем корректность конфига и перезагружаем Nginx для применения изменений:
```
sudo nginx -t
sudo systemctl restart nginx
```
Добавляем тестовый `info.php` для проверки работы PHP:
```
echo "<?php phpinfo(); ?>" | sudo tee /var/www/html/info.php
```
Добавляем правило фаервола для всего веб-трафика на порт 80:
```
sudo ufw allow 80
```
Проверка доступности:
```
http://YOUR_IP/info.php
```
## **2. Настройка Nginx для работы с phpMyAdmin**

### **2.1 Создаём символьную ссылку в `/var/www/html`**
```
sudo ln -s /usr/share/phpmyadmin /var/www/html/phpmyadmin
```
### **2.2 Настройка конфигурации Nginx**
1. Создаём новый конфиг:
```
sudo vim /etc/nginx/conf.d/default.conf
``` 
2. Вставляем:    
```
server {
	listen 80;
	server_name ваш_IP_или_домен;

	location /phpmyadmin {
		root /usr/share/;
		index index.php;
		try_files $uri $uri/ =404;

		location ~ \.php$ {
			include snippets/fastcgi-php.conf;
			fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
			fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
			include fastcgi_params;
		}
	}
}
```
    (Замените `php8.1-fpm.sock` на вашу версию PHP, например `php8.3-fpm.sock`).
3. Проверяем конфиг и перезапускаем Nginx:
```
sudo nginx -t
sudo systemctl restart nginx
```
Админка будет доступна по адресу:
```
http://YOUR_IP/phpmyadmin
```
Для доступа к MariaDB нужно ввести имя пользователя `root` и пароль, который вы ставили во время установки MariaDB. 
## **3. Запуск проекта с GitHub**
### **3.1 Установка Git**
```
sudo apt install git -y
```
### **3.2 Клонирование репозитория**
```
cd ~
sudo git clone https://github.com/username/repository.git
```
### **3.3 Копируем файлы проекта**
```
sudo mkdir -p /var/www/project
sudo cp -r MySite/* /var/www/project/
```
### **3.4 Настройка прав**
```
sudo chown -R www-data:www-data /var/www/html/simple-php-blog
sudo chmod -R 755 /var/www/html/simple-php-blog
```
### **3.5 Редактируем конфиг Nginx**
1. Переходим в наш конфиг, созданный для phpmyadmin:
```
sudo vim /etc/nginx/conf.d/default.conf
```
2. Добавляем в него строки:
```
    location /project {
        alias /var/www/project/;
        index index.html;
        try_files $uri $uri/ = 404;
    }
```
3. Проверяем корректность конфига
```
sudo nginx -t
# должно быть: syntax is ok
```
3. Перезагружаем Nginx
```
sudo systemctl restart nginx
```
3. Проверяем наш новый сайт по адресу:
```
http://YOUR_IP/project
```