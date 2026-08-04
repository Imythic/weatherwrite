"""RAG microservice for document Q&A using OpenAI embeddings + chat API.

Endpoints:
- POST /rag/ingest  -> build embeddings for buildings corpus (requires OPENAI_API_KEY)
- POST /rag/query   -> ask a question, returns answer + sources

This is a lightweight implementation that stores vectors in `rag_index.json`.
"""
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os
import json
import math
from typing import List

try:
    import openai
except Exception:
    openai = None

APP = FastAPI(title="RAG Service")

INDEX_FILE = os.path.join(os.path.dirname(__file__), "rag_index.json")
DATA_FILE = os.path.join(os.path.dirname(__file__), "buildings_data.json")


class QueryRequest(BaseModel):
    question: str
    top_k: int = 4


def load_documents():
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        raw = json.load(f)
    docs = []
    for b in raw:
        text = f"{b.get('name','')} in {b.get('city','')}, {b.get('state','')}. Roof {b.get('roof_size_sqft')} sqft. Cooling tower: {b.get('cooling_tower')}. Viability: {b.get('viability_score')} Score. Estimated annual savings ${b.get('estimated_annual_savings')}." 
        docs.append({"id": b.get("id"), "text": text, "meta": {"name": b.get("name"), "state": b.get("state")}})
    return docs


def embed_texts(texts: List[str], model: str = "text-embedding-3-small") -> List[List[float]]:
    if openai is None:
        raise RuntimeError("openai package not installed")
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        raise RuntimeError("OPENAI_API_KEY not set")
    openai.api_key = key
    resp = openai.Embedding.create(input=texts, model=model)
    return [r["embedding"] for r in resp["data"]]


def cosine(a, b):
    # pure-python cosine similarity
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(y * y for y in b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


@APP.post("/rag/ingest")
def ingest(force: bool = False):
    if openai is None:
        raise HTTPException(status_code=500, detail="openai package not available")
    if not os.environ.get("OPENAI_API_KEY"):
        raise HTTPException(status_code=400, detail="OPENAI_API_KEY not set in environment")

    if os.path.exists(INDEX_FILE) and not force:
        return {"status": "index exists", "path": INDEX_FILE}

    docs = load_documents()
    texts = [d["text"] for d in docs]
    embeddings = embed_texts(texts)

    index = {str(d["id"]): {"embedding": e, "meta": d["meta"], "text": d["text"]} for d, e in zip(docs, embeddings)}
    with open(INDEX_FILE, "w", encoding="utf-8") as f:
        json.dump(index, f)
    return {"status": "ingested", "count": len(index)}


@APP.post("/rag/query")
def query(q: QueryRequest):
    if openai is None:
        raise HTTPException(status_code=500, detail="openai package not available")
    if not os.path.exists(INDEX_FILE):
        raise HTTPException(status_code=400, detail="Index not found. POST /rag/ingest first.")
    if not os.environ.get("OPENAI_API_KEY"):
        raise HTTPException(status_code=400, detail="OPENAI_API_KEY not set in environment")

    with open(INDEX_FILE, "r", encoding="utf-8") as f:
        index = json.load(f)

    # embed query
    openai.api_key = os.environ.get("OPENAI_API_KEY")
    q_emb = embed_texts([q.question])[0]

    # compute similarities
    sims = []
    for doc_id, v in index.items():
        score = cosine(q_emb, v["embedding"])
        sims.append((score, doc_id, v))
    sims.sort(key=lambda x: x[0], reverse=True)
    top = sims[: q.top_k]

    # build prompt
    context = "\n\n".join([f"Source {t[1]}: {t[2]['text']}" for t in top])
    system = "You are an assistant answering a user question using only the provided sources. If the answer is not contained, say you don't know. Provide concise answer and cite source IDs." 
    prompt = f"{system}\n\nSources:\n{context}\n\nUser question: {q.question}\nAnswer:" 

    # call chat completion
    resp = openai.ChatCompletion.create(
        model=os.environ.get("OPENAI_MODEL", "gpt-3.5-turbo"),
        messages=[{"role": "system", "content": system}, {"role": "user", "content": prompt}],
        max_tokens=400,
        temperature=0.0,
    )
    answer = resp["choices"][0]["message"]["content"].strip()

    sources = [{"id": t[1], "score": t[0], "meta": t[2]["meta"]} for t in top]
    return {"answer": answer, "sources": sources}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("Rag:APP", host="0.0.0.0", port=8500, reload=True)
