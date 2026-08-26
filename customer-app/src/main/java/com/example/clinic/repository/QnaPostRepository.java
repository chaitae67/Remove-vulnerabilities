package com.example.clinic.repository;

import java.util.List;
import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.QnaPost;

public interface QnaPostRepository extends JpaRepository<QnaPost, Long> {
    List<QnaPost> findTop3ByOrderByCreatedAtDesc();

    List<QnaPost> findAllByOrderByCreatedAtDesc();

    @Query("SELECT p FROM QnaPost p LEFT JOIN FETCH p.attachments WHERE p.id = :id") 
    Optional<QnaPost> findByIdWithAttachments(@Param("id") Long id);

    List<QnaPost> findByWriterOrderByCreatedAtDesc(AppUser writer);
}
