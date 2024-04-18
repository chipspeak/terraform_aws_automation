from locust import HttpUser, between, task
import re

# pattern to search for in the about page html response. This metadata is is written to the about page by the user_data script in the launch template
pattern = r"This version of placemark is running on the following amazon linux ec2-instance:.*"
entry_break = "============================================================================================================================================================="

# locust class to simulate http requests to the load balancer with intervals of between 1 and 2 seconds between requests
class WebsiteUser(HttpUser):
  wait_time = between(1, 2)
  host = "http://placemark-alb-1476552651.us-east-1.elb.amazonaws.com"

  # on_start function to retrieve the login page and then use the authenticate post method with the seeded user credentials
  @task
  def login(self):
    self.client.get("/login")
    self.client.post("/authenticate", {
        "email": "homer@simpson.com",
        "password": "secret"
    })
  
  # function to retrieve the about page
  @task
  def about(self):
    response = self.client.get("/about")
    # if response is successful, re is used to search for the metadata pattern stored in the above variable
    if response.status_code == 200:
      html = response.text
      match = re.search(pattern, html)
      # if a match is found, the metadata is written to the file with a portion of the response header containing date/time
      if match:
        matched_text = match.group(0)
        headers = list(response.headers.items())[0]
        with open('load_balancer_test.txt', 'a') as file:
            file.write(f"{entry_break}\nRequest Header: {headers}\nMetadata: {matched_text}\n")

