import gradio as gr
import boto3
import time
import uuid
import os

# --- SETTINGS ---
# Write the bucket and table names that were created after running the bash script
# Keep the quotation marks!
BUCKET_NAME = "ENTER_BUCKET_NAME_HERE"  # Example: ai-gallery-1763811658-images
TABLE_NAME = "ENTER_TABLE_NAME_HERE" # Example: ai-gallery-1763811658-metadata
REGION = "us-east-1"

# AWS Connections
s3 = boto3.client('s3', region_name=REGION)
dynamodb = boto3.resource('dynamodb', region_name=REGION)
table = dynamodb.Table(TABLE_NAME)

def analyze_image(image_path):
    """
    1. Uploads image to S3.
    2. Waits for result to appear in DynamoDB.
    """
    if image_path is None:
        return "Please upload an image."

    try:
        # 1. Create filename (Unique ID)
        file_name = f"{uuid.uuid4()}.jpg"
        
        print(f"Uploading: {file_name}")
        
        # 2. Upload image to S3
        s3.upload_file(image_path, BUCKET_NAME, file_name)
        
        # 3. Wait for result (Polling)    
        max_retries = 30  
        for i in range(max_retries):
            response = table.get_item(Key={'image_id': file_name})
            
            if 'Item' in response:
                data = response['Item']
                description = data.get('description', 'No description')
                return description
            
            time.sleep(2) # Wait 2 seconds and ask again
            print(f"Waiting... ({i+1}/{max_retries})")
            
        return "Timeout: AI did not respond or Lambda encountered an error."

    except Exception as e:
        return f"An error occurred: {str(e)}"

# --- Gradio Interface ---
with gr.Blocks(title="AI Smart Gallery") as demo:
    gr.Markdown("# 🖼️ AI Image Analysis Assistant")
    gr.Markdown("Upload an image, and Bedrock (Claude 3.5) will analyze it for you.")
    
    with gr.Row():
        with gr.Column():
            input_image = gr.Image(type="filepath", label="Upload Image")
            analyze_btn = gr.Button("Analyze", variant="primary")
        
        with gr.Column():
            output_text = gr.Textbox(label="AI Analysis", lines=10)
    
    analyze_btn.click(fn=analyze_image, inputs=input_image, outputs=output_text)

if __name__ == "__main__":
    demo.launch()