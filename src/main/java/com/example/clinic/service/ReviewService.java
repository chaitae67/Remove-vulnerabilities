package com.example.clinic.service;

import java.util.List;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.domain.Review;
import com.example.clinic.repository.ProcedureProductRepository;
import com.example.clinic.repository.ReviewRepository;

@Service
public class ReviewService {

    private final ReviewRepository reviewRepository;
    private final ProcedureProductRepository procedureProductRepository;

    public ReviewService(ReviewRepository reviewRepository, ProcedureProductRepository procedureProductRepository) {
        this.reviewRepository = reviewRepository;
        this.procedureProductRepository = procedureProductRepository;
    }

    public List<Review> findAll() {
        return reviewRepository.findAllByOrderByCreatedAtDesc();
    }

    public List<Review> findLatest() {
        return reviewRepository.findTop3ByOrderByCreatedAtDesc();
    }

    public Review findById(Long id) {
        return reviewRepository.findById(id)
            .orElseThrow(() -> new IllegalArgumentException("후기를 찾을 수 없습니다."));
    }

    @Transactional
    public Review create(String title, String content, int rating, Long procedureProductId, AppUser writer) {
        Review review = new Review();
        review.setTitle(title);
        review.setContent(content);
        review.setRating(clampRating(rating));
        review.setWriter(writer);
        review.setProcedureProduct(resolveProcedure(procedureProductId));
        return reviewRepository.save(review);
    }

    // No ownership check: any caller can rewrite any review by id (IDOR).
    @Transactional
    public void update(Long id, String title, String content, int rating, Long procedureProductId) {
        Review review = findById(id);
        review.setTitle(title);
        review.setContent(content);
        review.setRating(clampRating(rating));
        review.setProcedureProduct(resolveProcedure(procedureProductId));
    }

    // No ownership check: any caller can delete any review by id (IDOR).
    @Transactional
    public void delete(Long id) {
        reviewRepository.delete(findById(id));
    }

    private ProcedureProduct resolveProcedure(Long procedureProductId) {
        if (procedureProductId == null) {
            return null;
        }
        return procedureProductRepository.findById(procedureProductId).orElse(null);
    }

    private int clampRating(int rating) {
        return Math.max(1, Math.min(5, rating));
    }
}
