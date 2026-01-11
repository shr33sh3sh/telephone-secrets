# Use Nginx to serve static HTML files
FROM nginx:alpine

# Copy HTML files to Nginx serve directory
COPY src/ /usr/share/nginx/html/

# Copy custom Nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Expose port 80
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]