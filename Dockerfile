FROM nginx:alpine

WORKDIR /var/www/html/vdo.ninja

COPY . .

COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]