ARG MODULE_PATH
ARG JAR_GLOB

FROM maven:3.9.11-eclipse-temurin-21 AS build

ARG MODULE_PATH

WORKDIR /app

COPY . .

RUN test -n "${MODULE_PATH}"
RUN mvn -B -pl "${MODULE_PATH}" -am clean package -DskipTests

FROM eclipse-temurin:21-jre

ARG MODULE_PATH
ARG JAR_GLOB

WORKDIR /app

COPY docker/entrypoint.sh /app/entrypoint.sh
COPY --from=build /app/${MODULE_PATH}/target/${JAR_GLOB} /app/app.jar

RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["java", "-jar", "/app/app.jar"]
