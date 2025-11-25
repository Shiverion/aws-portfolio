"""
Portfolio chatbot endpoint for the backend API.
This module provides a separate endpoint for the portfolio Career Twin chatbot.
"""

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Optional, List, Dict
import uuid
from datetime import datetime
import boto3
from botocore.exceptions import ClientError
import os
import json

from portfolio_context import portfolio_prompt

# Create router
router = APIRouter()

# Initialize Bedrock client
bedrock_client = boto3.client(
    service_name="bedrock-runtime",
    region_name=os.getenv("DEFAULT_AWS_REGION", "us-east-1")
)

BEDROCK_MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "amazon.nova-lite-v1:0")
USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = os.getenv("MEMORY_DIR", "../memory")

if USE_S3:
    s3_client = boto3.client("s3")


# Request/Response models
class PortfolioChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None


class PortfolioChatResponse(BaseModel):
    response: str
    session_id: str


def get_portfolio_memory_path(session_id: str) -> str:
    return f"portfolio_{session_id}.json"


def load_portfolio_conversation(session_id: str) -> List[Dict]:
    """Load portfolio conversation history from storage"""
    if USE_S3:
        try:
            response = s3_client.get_object(
                Bucket=S3_BUCKET, Key=get_portfolio_memory_path(session_id)
            )
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchKey":
                return []
            raise
    else:
        # Local file storage
        file_path = os.path.join(MEMORY_DIR, get_portfolio_memory_path(session_id))
        if os.path.exists(file_path):
            with open(file_path, "r") as f:
                return json.load(f)
        return []


def save_portfolio_conversation(session_id: str, messages: List[Dict]):
    """Save portfolio conversation history to storage"""
    if USE_S3:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=get_portfolio_memory_path(session_id),
            Body=json.dumps(messages, indent=2),
            ContentType="application/json",
        )
    else:
        # Local file storage
        os.makedirs(MEMORY_DIR, exist_ok=True)
        file_path = os.path.join(MEMORY_DIR, get_portfolio_memory_path(session_id))
        with open(file_path, "w") as f:
            json.dump(messages, f, indent=2)


def call_bedrock_portfolio(conversation: List[Dict], user_message: str) -> str:
    """Call AWS Bedrock with portfolio-specific prompt"""

    # Build messages in Bedrock format
    messages = []

    # Add portfolio system prompt
    messages.append({
        "role": "user",
        "content": [{"text": f"System: {portfolio_prompt()}"}]
    })

    # Add conversation history
    for msg in conversation[-20:]:
        messages.append({
            "role": msg["role"],
            "content": [{"text": msg["content"]}]
        })

    # Add current user message
    messages.append({
        "role": "user",
        "content": [{"text": user_message}]
    })

    try:
        response = bedrock_client.converse(
            modelId=BEDROCK_MODEL_ID,
            messages=messages,
            inferenceConfig={
                "maxTokens": 2000,
                "temperature": 0.7,
                "topP": 0.9
            }
        )

        return response["output"]["message"]["content"][0]["text"]

    except ClientError as e:
        error_code = e.response['Error']['Code']
        if error_code == 'ValidationException':
            print(f"Bedrock validation error: {e}")
            raise HTTPException(status_code=400, detail="Invalid message format")
        elif error_code == 'AccessDeniedException':
            print(f"Bedrock access denied: {e}")
            raise HTTPException(status_code=403, detail="Access denied to Bedrock")
        else:
            print(f"Bedrock error: {e}")
            raise HTTPException(status_code=500, detail=f"Bedrock error: {str(e)}")


@router.post("/api/chat/portfolio", response_model=PortfolioChatResponse)
async def portfolio_chat(request: PortfolioChatRequest):
    """Portfolio Career Twin chatbot endpoint"""
    try:
        session_id = request.session_id or str(uuid.uuid4())

        # Load conversation history
        conversation = load_portfolio_conversation(session_id)

        # Call Bedrock with portfolio prompt
        assistant_response = call_bedrock_portfolio(conversation, request.message)

        # Update conversation history
        conversation.append({
            "role": "user",
            "content": request.message,
            "timestamp": datetime.now().isoformat()
        })
        conversation.append({
            "role": "assistant",
            "content": assistant_response,
            "timestamp": datetime.now().isoformat()
        })

        # Save conversation
        save_portfolio_conversation(session_id, conversation)

        return PortfolioChatResponse(response=assistant_response, session_id=session_id)

    except HTTPException:
        raise
    except Exception as e:
        print(f"Error in portfolio chat endpoint: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))
