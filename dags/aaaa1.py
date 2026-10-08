from datetime import datetime

from airflow.sdk import dag, task


@dag(dag_id="aaaa1", start_date=datetime(2024, 1, 1), schedule=None, catchup=False)
def aaaa1():
    @task
    def hello_world():
        print("="*100)
        print("Hello World")
        print("="*100)

    hello_world()


aaaa1()