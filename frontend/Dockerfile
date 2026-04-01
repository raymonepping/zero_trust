FROM node:25.8.2-alpine3.23

WORKDIR /app

COPY package.json .
RUN npm install

COPY . .

EXPOSE 5173

CMD ["npx", "vite", "--host"]
