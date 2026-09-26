# Selectivity band, recognize an ambiguous referent and resolve it by enumerating candidates rather than assuming one.

Is the database healthy?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "harbor"
- synthesis does NOT CONTAIN "no database components"

```reflects
The cluster runs several real datastores and their health IS determinable from live state. A correct answer recognizes that 'the database' is ambiguous, discovers the datastores rather than assuming a single one, and reports each one's health. The datastores currently present and running include harbor-database (PostgreSQL) and sonarqube-postgresql, plus harbor-redis and the nats store; saying no database components were found is wrong. A correct answer enumerates the real datastores it finds and reports them healthy. (The exact set may drift; the constant is discovering and reporting the actual datastores present.)
```
