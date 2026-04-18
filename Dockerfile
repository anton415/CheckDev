FROM maven:3.9.11-eclipse-temurin-21 AS build

WORKDIR /app

COPY . .

RUN mvn -B -pl services/site -am clean package -DskipTests

FROM eclipse-temurin:21-jre

WORKDIR /app

COPY --from=build /app/services/site/target/site-*.jar app.jar

CMD ["java", "-jar", "app.jar"]
