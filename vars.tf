locals {
    image_id = "YOUR_AMI_ID"
    pem = "YOUR_PEM_FILE"
    user_data = <<-EOF
            #!/bin/bash
            TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
            INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
            INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
            AVAILABILITY_ZONE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
            sed -i "19i <br>\n<br>\nThis version of placemark is running on the following amazon linux ec2-instance: $INSTANCE_ID in the following availability zone: $AVAILABILITY_ZONE" /home/ec2-user/Web-Server/placemark/src/views/about-view.hbs
            EOF
}

# helpful suggestion from Kieron Garvey
variable "default_tags" {
    default = {
        StudentName = "Patrick O'Connor"
        StudentNumber = "20040412"
        Assignment = "DevOps Assignment 2"
        Terraform = "true"
        Environment = "dev"
    }
}
