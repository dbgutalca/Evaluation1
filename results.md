## RocksDB

|**Métrica**|**SF0.1**|**SF0.3**|**SF1**| **SF3**|
|---|---|---|---|---|
|**Tiempo Ingesta**|6498.372 ms|16560.538 ms|62340.063 ms|241303.058ms|
|**Tamaño en Disco**|78 MB|236 MB|784 MB|2.6 GB|
|**Avg Q1 (getNode)**|0.1211 ms|0.0478 ms|0.0623 ms| 0.7514 ms|
|**Avg Q2 (EdgesByLabel)**|67.3970 ms|178.8087 ms|559.0945 ms|1933.7372 ms|
|**Avg Q3 (PropEquals)**|8.9787 ms|18.0211 ms|54.0471 ms|161.9814 ms|

## Sparksee

|**Métrica**|**SF0.1**|**SF0.3**|**SF1**|**SF3**|
|---|---|---|---|---|
|**Tiempo Ingesta**|18442.171 ms|57463.811 ms|262077.067 ms|1487714.335ms|
|**Tamaño en Disco**|327 MB|968 MB|3.4 GB|12 GB|
|**Avg Q1 (getNode)**|0.2501 ms|2.8663 ms|3.5242 ms|0.2567 ms|
|**Avg Q2 (EdgesByLabel)**|90.5112 ms|625.4308 ms|2186.936 ms|6986.2622 ms |
|**Avg Q3 (PropEquals)**|39.1248 ms|300.4478 ms|938.3927 ms| 3346.2094 ms |

## MapDB

|**Métrica**|**SF0.1**|**SF0.3**|**SF1**|**SF3**|
|---|---|---|---|---|
|**Tiempo Ingesta**|334769.699 ms|1130024.679 ms|4026554.396 ms|27850078.700 ms|
|**Tamaño en Disco**| 688MB| 2.1GB | 8GB| 25GB |
|**Avg Q1 (getNode)**|0.6649 ms|2.1360 ms|2.0118 ms| 0.3315 ms |
|**Avg Q2 (EdgesByLabel)**|197.8945 ms|696.6590 ms|2443.3827 ms| 12184.3062 ms |
|**Avg Q3 (PropEquals)**|14.0717 ms|342.0634 ms|1137.3814 ms| 2972.2197 ms |

## PostgreSQL

|**Métrica**|**SF0.1**|**SF0.3**|**SF1**|**SF3**|
|---|---|---|---|---|
|**Tiempo Ingesta**|119309.447 ms|369278.120 ms| 1458781.624 ms| 5316970.863ms |
|**Tamaño en Disco**| 512MB| 1.5GB | 5.4GB| 20 GB |
|**Avg Q1 (getNode)**|1.6363 ms|1.7706 ms|1.5938 ms| 0.4460 ms|
|**Avg Q2 (EdgesByLabel)**|134.4088 ms|649.4239 ms|1812.0225 ms| 9466.7663ms |
|**Avg Q3 (PropEquals)**|20.2578 ms|376.4215 ms|719.3075 ms| 519.3874ms |

## Neo4j

|**Métrica**|**SF0.1**|**SF0.3**|**SF1**| **SF3**|
|---|---|---|---|---|
|**Tiempo Ingesta**|149507.311 ms|486198.988 ms| 2103374.194 ms| 6741912.999ms|
|**Tamaño en Disco**| 259MB| 858MB | 2.4GB| 13GB |
|**Avg Q1 (getNode)**|6.2573 ms|6.8204 ms|6.8277 ms| 5.9188ms |
|**Avg Q2 (EdgesByLabel)**|661.3470 ms|1465.5089 ms|4934.9867 ms| 13047.9190ms |
|**Avg Q3 (PropEquals)**|500.2703 ms|1415.0587 ms| 4774.0606 ms| 14103.0819ms |
