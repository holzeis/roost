// Package storage wraps the MinIO client for shared images/video (FR2.*).
// Per the architecture decision that MinIO is never tailnet-exposed, all
// access goes through the chat server: clients upload to and download from
// the server, and the server is the only thing that ever talks to MinIO.
package storage

import (
	"context"
	"fmt"
	"io"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

type Store struct {
	client *minio.Client
	bucket string
}

func New(ctx context.Context, endpoint, accessKey, secretKey, bucket string, useSSL bool) (*Store, error) {
	client, err := minio.New(endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(accessKey, secretKey, ""),
		Secure: useSSL,
	})
	if err != nil {
		return nil, fmt.Errorf("storage: create client: %w", err)
	}

	exists, err := client.BucketExists(ctx, bucket)
	if err != nil {
		return nil, fmt.Errorf("storage: check bucket: %w", err)
	}
	if !exists {
		if err := client.MakeBucket(ctx, bucket, minio.MakeBucketOptions{}); err != nil {
			return nil, fmt.Errorf("storage: create bucket: %w", err)
		}
	}

	return &Store{client: client, bucket: bucket}, nil
}

func (s *Store) Bucket() string { return s.bucket }

// Put uploads an object and returns nothing beyond error — the caller
// already knows the key it chose (see internal/api's media upload handler,
// which generates the key before calling this).
func (s *Store) Put(ctx context.Context, key string, body io.Reader, size int64, contentType string) error {
	_, err := s.client.PutObject(ctx, s.bucket, key, body, size, minio.PutObjectOptions{ContentType: contentType})
	if err != nil {
		return fmt.Errorf("storage: put object: %w", err)
	}
	return nil
}

// Get returns a reader for the object; the caller must close it.
func (s *Store) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	obj, err := s.client.GetObject(ctx, s.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, fmt.Errorf("storage: get object: %w", err)
	}
	// GetObject doesn't itself error on a missing key — Stat does, and
	// surfaces a real 404 instead of a stream that fails on first read.
	if _, err := obj.Stat(); err != nil {
		obj.Close()
		return nil, fmt.Errorf("storage: stat object: %w", err)
	}
	return obj, nil
}

// Copy duplicates an object under a new key, server-side (no bytes pass
// through this process) — used when forwarding a media message, so the
// forwarded copy has its own independent object that can be deleted without
// affecting the original (see docs/data-model.md's forward semantics).
func (s *Store) Copy(ctx context.Context, srcKey, dstKey string) error {
	src := minio.CopySrcOptions{Bucket: s.bucket, Object: srcKey}
	dst := minio.CopyDestOptions{Bucket: s.bucket, Object: dstKey}
	if _, err := s.client.CopyObject(ctx, dst, src); err != nil {
		return fmt.Errorf("storage: copy object: %w", err)
	}
	return nil
}

func (s *Store) Delete(ctx context.Context, key string) error {
	if err := s.client.RemoveObject(ctx, s.bucket, key, minio.RemoveObjectOptions{}); err != nil {
		return fmt.Errorf("storage: delete object: %w", err)
	}
	return nil
}
