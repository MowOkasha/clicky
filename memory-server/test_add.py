import os
from mem0 import Memory

config = {
    "vector_store": {
        "provider": "qdrant",
        "config": {
            "collection_name": "clicky_memories",
            "path": "./qdrant_data",
        }
    },
    "llm": {
        "provider": "ollama",
        "config": {
            "model": "qwen2.5:7b",
            "ollama_base_url": "http://localhost:11434"
        }
    },
    "embedder": {
        "provider": "ollama",
        "config": {
            "model": "qwen2.5:7b",
            "ollama_base_url": "http://localhost:11434"
        }
    }
}

memory = Memory.from_config(config)
try:
    memory.add([{"role": "user", "content": "hello"}], user_id="test")
except Exception as e:
    import traceback
    traceback.print_exc()
