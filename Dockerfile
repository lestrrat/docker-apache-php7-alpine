FROM alpine:3.4

ADD build.sh $WORKDIR
ADD docker-php-source /usr/local/bin/
RUN ./build.sh

WORKDIR "/var/www/html"
EXPOSE 8000
ADD apache2-foreground /usr/local/bin/
CMD ["apache2-foreground"]
