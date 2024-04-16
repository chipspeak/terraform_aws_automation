import boto3
import os
import json

# function to increase the max instances of the autoscaling group
# this function will be called via cloudwatch in the event that the custom metric SCALING_NEEDED is triggered for 10 datapoints in 10 minutes
# this would imply that there is high traffic and cpu consumption and the current scaling options are insufficient to relieve this stress on the asg
def lambda_handler(event, context):
  try:
    # parsing cloudwatch alarm name and description
    alarm_name = event['Records'][0]['Sns']['Subject']
    alarm_description = event['Records'][0]['Sns']['Message']
    
    # checking if alarm is in ALARM state
    if "ALARM" in alarm_description:
      # declaring the asg_name from the environment variable created via terraform
      asg_name = os.environ['ASG_NAME']
      # declaring the autoscaling client via boto3 library
      autoscaling_client = boto3.client('autoscaling')
      # declaring the response variable
      response = autoscaling_client.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
      # getting the current max size of the autoscaling group (3 by default via terraform setup)
      current_max_size = response['AutoScalingGroups'][0]['MaxSize']
      if current_max_size >= 10:
        return {
            'statusCode': 200,
            'body': 'Max instances already at maximum limit of 10'
        }
      else:
        # increasing max size by 1
        new_max_size = current_max_size + 1
        # updating the autoscaling group with the new max size
        response = autoscaling_client.update_auto_scaling_group(
            AutoScalingGroupName=asg_name,
            MaxSize=new_max_size
        )
        # return a success message
        return {
            'statusCode': 200,
            'body': 'Max instances increased to ' + str(new_max_size)
        }
    # if the alarm is in OK state, return a success message
    else:
      return {
          'statusCode': 200,
          'body': 'No action taken. Alarm state: OK'
      }
  # throw an exception if any error occurs
  except Exception as e:
    return {
        'statusCode': 500,
        'body': 'Error: ' + str(e)
    }
