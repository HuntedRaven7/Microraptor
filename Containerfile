# Lint helper only for an already-built Microraptor image.
# Do not add package installation or overlay logic here; Microraptor image contents
# come from BuildStream elements and OCI assembly `.bst` files.
FROM ghcr.io/${{ github.repository_owner }}/microraptor:latest

RUN bootc container lint || true