# Dockerfile
FROM nginx:alpine

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy Jekyll _site to nginx public directory
COPY _site /usr/share/nginx/html
