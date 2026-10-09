"""
DAG de prueba del clúster Celery.

- 10 tareas en paralelo en la cola "default": se reparten entre todos los workers.
- 1 tarea en la cola "dan": solo la ejecuta el worker que atienda esa cola
  (en su .env: WORKER_QUEUES=default,dan).
- Una tarea final que resume qué máquina hizo cada cosa.

Cada tarea devuelve el nombre de la máquina donde corrió; míralo en el log
de la tarea, en Flower (Tasks) o en el resumen final.
"""
import socket
import time

import pendulum
from airflow.sdk import dag, task


@dag(
    schedule=None,
    start_date=pendulum.datetime(2026, 1, 1, tz="UTC"),
    catchup=False,
    tags=["demo", "celery"],
)
def demo_cluster():

    @task
    def trabajo(n: int) -> str:
        maquina = socket.gethostname()
        print(f"Tarea {n} ejecutándose en: {maquina}")
        time.sleep(5)  # simula trabajo, para que se repartan entre workers
        return maquina

    @task(queue="dan")
    def solo_en_pc_de_dan() -> str:
        maquina = socket.gethostname()
        print(f"Esta tarea solo la toma el worker de la cola 'dan': {maquina}")
        return maquina

    @task
    def resumen(maquinas: list[str], maquina_dan: str) -> None:
        conteo: dict[str, int] = {}
        for m in maquinas:
            conteo[m] = conteo.get(m, 0) + 1
        print("Tareas en paralelo por máquina:")
        for m, c in conteo.items():
            print(f"  {m}: {c}")
        print(f"Tarea de la cola 'dan' corrió en: {maquina_dan}")

    resumen(trabajo.expand(n=list(range(1, 11))), solo_en_pc_de_dan())


demo_cluster()
