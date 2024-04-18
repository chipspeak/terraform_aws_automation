#!/bin/bash

# log file
LOG_FILE="/home/ec2-user/monitoring.log"

# log start of execution
echo "=================================================================================" >> "$LOG_FILE"
echo "Script execution started on $(date)" >> "$LOG_FILE"
echo " " >> "$LOG_FILE"

# retrieve instance metadata
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
AVAILABILITY_ZONE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
AUTOSCALING_GROUP=$(aws autoscaling describe-auto-scaling-instances --instance-ids $INSTANCE_ID --query "AutoScalingInstances[0].AutoScalingGroupName" --output text)

# retrieve IO wait percentage via iostat piped to awk. NR==4 is used to get the 4th line before printing the 5th column of that line
IO_WAIT=$(iostat | awk 'NR==4 {print $5}')

# retrieve CPU usage via top -bn1 (to run top once) piped into grep to get the line with "Cpu(s)"
# regex is used to skip the initial text on each line, the second group accounts for the floating point by matching any number of digits and a period followed by a % 
# before matching id for idle time the awk command then subtracts the idle time from 100 to get the CPU usage
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')

# retrieve connection speed via fast.com before routing the returned contents to /dev/null and using curl's -w flag to print the speed_download in kb/s
CONNECTION_SPEED=$(curl -s -w "%{speed_download}\n" -o /dev/null https://fast.com)

# retrieve memory usage via free -m and awk to get the second line and calculate the percentage of used memory via awk multiplying 
# the third column (used memory) by 100 and dividing by the second column (total memory)
USEDMEMORY=$(free -m | awk 'NR==2{printf "%.2f\t", $3*100/$2 }')

# retrieve HTTP connection count using grep to check for port 3000 (this obviously only counts conncurrent at the time of script execution)
HTTP_CONN=$(netstat -an | grep ':3000 ' | wc -l)

# instance is overloaded if IO wait is more than 70% and memory is more than 80% (echo used here and in the following if statements to compare floating point numbers)
if (( $(echo "$IO_WAIT > 70" | bc -l) )) && (( $(echo "$USEDMEMORY > 80" | bc -l) )); then
  INSTANCE_OVERLOADED=1
else
  INSTANCE_OVERLOADED=0
fi

# if cpu is overtaxed and http connections are more than 70, scaling is needed (these values were chosen after locust testing)
if (( $(echo "$CPU_USAGE > 70" | bc -l) )) && (( $HTTP_CONN > 70 )); then
  SCALING_NEEDED=1
else
  SCALING_NEEDED=0
fi

# overall check for high http traffic
if (( $HTTP_CONN > 40 )); then
  HIGH_HTTP_TRAFFIC=1
else
  HIGH_HTTP_TRAFFIC=0
fi


# log retrieved metrics
echo "Metrics for: $INSTANCE_ID" >> "$LOG_FILE"
echo " " >> "$LOG_FILE"
echo "Autoscaling Group: $AUTOSCALING_GROUP" >> "$LOG_FILE"
echo "CPU Usage: $CPU_USAGE%" >> "$LOG_FILE"
echo "IO Wait: $IO_WAIT%" >> "$LOG_FILE"
echo "Connection Speed in kb/s: $CONNECTION_SPEED" >> "$LOG_FILE"
echo "Memory Usage: $USEDMEMORY" >> "$LOG_FILE"
echo "HTTP Connections: $HTTP_CONN" >> "$LOG_FILE"


# push metrics to CloudWatch and redirect output to log file in order to capture any errors
aws cloudwatch put-metric-data --metric-name cpu-usage --dimensions AutoScalingGroupName=$AUTOSCALING_GROUP --namespace "Custom" --value $CPU_USAGE >> "$LOG_FILE" 2>&1
aws cloudwatch put-metric-data --metric-name io-wait --dimensions AutoScalingGroupName=$AUTOSCALING_GROUP --namespace "Custom" --value $IO_WAIT >> "$LOG_FILE" 2>&1
aws cloudwatch put-metric-data --metric-name connection-speed-kb/s --dimensions AutoScalingGroupName=$AUTOSCALING_GROUP --namespace "Custom" --value $CONNECTION_SPEED >> "$LOG_FILE" 2>&1
aws cloudwatch put-metric-data --metric-name memory-usage --dimensions AutoScalingGroupName=$AUTOSCALING_GROUP --namespace "Custom" --value $USEDMEMORY >> "$LOG_FILE" 2>&1
aws cloudwatch put-metric-data --metric-name http-connections --dimensions AutoScalingGroupName=$AUTOSCALING_GROUP --namespace "Custom" --value $HTTP_CONN >> "$LOG_FILE" 2>&1
aws cloudwatch put-metric-data --metric-name instance-overloaded --dimensions AutoScalingGroupName=$AUTOSCALING_GROUP --namespace "Custom" --value $INSTANCE_OVERLOADED >> "$LOG_FILE" 2>&1
aws cloudwatch put-metric-data --metric-name scaling-needed --dimensions AutoScalingGroupName=$AUTOSCALING_GROUP --namespace "Custom" --value $SCALING_NEEDED >> "$LOG_FILE" 2>&1
aws cloudwatch put-metric-data --metric-name high-http-traffic --dimensions AutoScalingGroupName=$AUTOSCALING_GROUP --namespace "Custom" --value $HIGH_HTTP_TRAFFIC >> "$LOG_FILE" 2>&1

if (( INSTANCE_OVERLOADED == 1 )); then
  echo "Instance is overloaded!" >> "$LOG_FILE"
fi

if (( SCALING_NEEDED == 1 )); then
  echo "High CPU Usage detected. Scaling needed immediately!" >> "$LOG_FILE"
fi

if (( HIGH_HTTP_TRAFFIC == 1 )); then
  echo "High HTTP traffic detected!" >> "$LOG_FILE"
fi

# log end of execution
echo " " >> "$LOG_FILE"
echo "Script execution completed on $(date)" >> "$LOG_FILE"