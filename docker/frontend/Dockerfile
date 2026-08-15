# docker/frontend/Dockerfile
# Build from the REPO ROOT:  docker build -f docker/frontend/Dockerfile -t vm-order-frontend:1.0.0 .
# Official NON-root nginx variant. It listens on 8080 because processes
# without root cannot bind ports below 1024.
FROM nginxinc/nginx-unprivileged:1.27-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0

# Static page (unchanged from phase 2)
COPY --chmod=0644 app/index.html /usr/share/nginx/html/index.html

# The ONE real change of phase 3: proxy_pass points to the Kubernetes
# Service NAME instead of a templated private IP (see nginx.conf)
COPY --chmod=0644 docker/frontend/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080
# CMD inherited from the base image (nginx -g "daemon off;")
