package com.example.clinic.service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.Resource;
import org.springframework.core.io.UrlResource;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;
import org.springframework.web.multipart.MultipartFile;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.domain.Review;
import com.example.clinic.domain.ReviewAttachment;
import com.example.clinic.repository.ProcedureProductRepository;
import com.example.clinic.repository.ReviewRepository;

@Service
public class ReviewService {

    private final ReviewRepository reviewRepository;
    private final ProcedureProductRepository procedureProductRepository;
    private final Path reviewUploadPath;

    public ReviewService(ReviewRepository reviewRepository,
                          ProcedureProductRepository procedureProductRepository,
                          @Value("${app.upload-dir:uploads}") String uploadDir) {
        this.reviewRepository = reviewRepository;
        this.procedureProductRepository = procedureProductRepository;
        this.reviewUploadPath = Path.of(uploadDir).resolve("reviews").toAbsolutePath().normalize();
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

    public ReviewAttachment findAttachment(Review review, Long attachmentId) {
        return review.getAttachments().stream()
            .filter(attachment -> attachment.getId().equals(attachmentId))
            .findFirst()
            .orElseThrow(() -> new IllegalArgumentException("첨부파일을 찾을 수 없습니다."));
    }

    public Resource loadAttachment(ReviewAttachment attachment) {
        try {
            Path filePath = reviewUploadPath.resolve(attachment.getStoredFilename()).normalize();
            if (!filePath.startsWith(reviewUploadPath)) {
                throw new IllegalArgumentException("잘못된 파일 경로입니다.");
            }
            Resource resource = new UrlResource(filePath.toUri());
            if (resource.exists() && resource.isReadable()) {
                return resource;
            }
            throw new IllegalArgumentException("파일을 찾을 수 없습니다.");
        } catch (java.net.MalformedURLException ex) {
            throw new IllegalStateException("파일을 불러오는 중 오류가 발생했습니다.", ex);
        }
    }

    @Transactional
    public Review create(String title, String content, int rating, Long procedureProductId, AppUser writer, MultipartFile[] files) {
        Review review = new Review();
        review.setTitle(title);
        review.setContent(content);
        review.setRating(clampRating(rating));
        review.setWriter(writer);
        review.setProcedureProduct(resolveProcedure(procedureProductId));
        attachFiles(review, files);
        return reviewRepository.save(review);
    }

    // No ownership check: any caller can rewrite any review by id (IDOR).
    @Transactional
    public void update(Long id, String title, String content, int rating, Long procedureProductId, MultipartFile[] files) {
        Review review = findById(id);
        review.setTitle(title);
        review.setContent(content);
        review.setRating(clampRating(rating));
        review.setProcedureProduct(resolveProcedure(procedureProductId));
        attachFiles(review, files);
    }

    // No ownership check: any caller can delete any review by id (IDOR).
    @Transactional
    public void delete(Long id) {
        reviewRepository.delete(findById(id));
    }

    private void attachFiles(Review review, MultipartFile[] files) {
        if (files == null) {
            return;
        }
        for (MultipartFile file : files) {
            if (!file.isEmpty()) {
                review.addAttachment(store(file));
            }
        }
    }

    // 이미지만 첨부 가능하다고 안내하지만 확장자/콘텐츠 타입 검증이 없어
    // .php 등 어떤 파일이든 그대로 저장되고 /uploads/reviews 로 서빙된다.
    private ReviewAttachment store(MultipartFile file) {
        try {
            Files.createDirectories(reviewUploadPath);
            String original = StringUtils.cleanPath(file.getOriginalFilename() == null ? "attachment" : file.getOriginalFilename());
            String extension = "";
            int extensionIndex = original.lastIndexOf('.');
            if (extensionIndex >= 0) {
                extension = original.substring(extensionIndex);
            }
            String stored = UUID.randomUUID() + extension;
            file.transferTo(reviewUploadPath.resolve(stored));

            ReviewAttachment attachment = new ReviewAttachment();
            attachment.setOriginalFilename(original);
            attachment.setStoredFilename(stored);
            attachment.setContentType(file.getContentType());
            attachment.setSize(file.getSize());
            return attachment;
        } catch (IOException ex) {
            throw new IllegalStateException("첨부파일 저장 중 오류가 발생했습니다.", ex);
        }
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
