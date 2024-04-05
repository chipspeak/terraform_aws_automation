from locust import HttpUser, between, task

# simple locust test to generate http traffic to the load balancer
class WebsiteUser(HttpUser):
    wait_time = between(1, 2)
    host = "your_load_balancer_dns_name"
        
    @task
    def about(self):
        self.client.get("/login")