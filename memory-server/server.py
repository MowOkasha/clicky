from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from mem0 import Memory
import os

app = FastAPI()

# Configure Mem0 to use local Qdrant (file persistence) and Ollama for embeddings/llm
config = {
    "vector_store": {
        "provider": "qdrant",
        "config": {
            "collection_name": "clicky_memories",
            "path": "./qdrant_data",  # Local file persistence
        }
    },
    "llm": {
        "provider": "ollama",
        "config": {
            "model": "qwen2.5:7b",
            "base_url": "http://localhost:11434"
        }
    },
    "embedder": {
        "provider": "ollama",
        "config": {
            "model": "qwen2.5:7b",
            "base_url": "http://localhost:11434"
        }
    }
}

try:
    memory = Memory.from_config(config)
    print("Mem0 initialized with Qdrant and Ollama")
except Exception as e:
    print(f"Warning: Failed to initialize Mem0: {e}")
    memory = None

class AddRequest(BaseModel):
    user_id: str
    messages: list[dict[str, str]]

class SearchRequest(BaseModel):
    user_id: str
    query: str
    limit: int = 5

@app.get("/health")
def health_check():
    if memory is None:
        raise HTTPException(status_code=503, detail="Mem0 not initialized")
    return {"status": "ok"}

@app.post("/add")
def add_memory(req: AddRequest):
    if memory is None:
        raise HTTPException(status_code=503, detail="Mem0 not initialized")
    
    try:
        # Mem0 will extract memories from the messages and store them
        result = memory.add(req.messages, user_id=req.user_id)
        return {"status": "success", "result": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/search")
def search_memory(req: SearchRequest):
    if memory is None:
        raise HTTPException(status_code=503, detail="Mem0 not initialized")
    
    try:
        # Search for memories
        results = memory.search(query=req.query, user_id=req.user_id, limit=req.limit)
        return {"status": "success", "results": results}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8769)
