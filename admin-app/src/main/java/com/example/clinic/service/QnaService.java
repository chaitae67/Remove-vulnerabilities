package com.example.clinic.service;

import java.io.IOException;
import java.net.MalformedURLException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDateTime;
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
import com.example.clinic.domain.QnaAttachment;
import com.example.clinic.domain.QnaPost;
import com.example.clinic.repository.QnaPostRepository;

@Service
public class QnaService {

    private final QnaPostRepository qnaPostRepository;
    private final Path qnaUploadPath;

    public QnaService(QnaPostRepository qnaPostRepository, @Value("${app.upload-dir:uploads}") String uploadDir) {
        this.qnaPostRepository = qnaPostRepository;
        this.qnaUploadPath = Path.of(uploadDir).resolve("qna").toAbsolutePath().normalize();
    }

    public List<QnaPost> findLatest() {
        return qnaPostRepository.findTop3ByOrderByCreatedAtDesc();
    }

    public List<QnaPost> findAll() {
        return qnaPostRepository.findAllByOrderByCreatedAtDesc();
    }

    public QnaPost findByIdWithAttachments(Long id) {
        return qnaPostRepository.findByIdWithAttachments(id)
            .orElseThrow(() -> new IllegalArgumentException("상담 글을 찾을 수 없습니다."));
    }

    @Transactional
    public QnaPost create(String title, String content, String phone, boolean privatePost, AppUser writer, MultipartFile[] files) {
        QnaPost post = new QnaPost();
        post.setTitle(title);
        post.setContent(content);
        post.setPhone(phone);
        post.setPrivatePost(privatePost);
        post.setWriter(writer);

        if (files != null) {
            for (MultipartFile file : files) {
                if (!file.isEmpty()) {
                    post.addAttachment(store(file));
                }
            }
        }
        return qnaPostRepository.save(post);
    }

    @Transactional
    public void delete(Long id) {
        qnaPostRepository.deleteById(id);
    }

    @Transactional
    public void answer(Long id, String answer) {
        QnaPost post = findByIdWithAttachments(id);
        post.setAnswer(answer);
        post.setAnswered(true);
        post.setAnsweredAt(LocalDateTime.now());
    }

    public Resource loadAttachment(String filename) {
        try {
            Path filePath = qnaUploadPath.resolve(filename).normalize();
            if (!filePath.startsWith(qnaUploadPath)) {
                throw new IllegalArgumentException("잘못된 파일 경로입니다.");
            }
            Resource resource = new UrlResource(filePath.toUri());
            if (resource.exists() && resource.isReadable()) {
                return resource;
            }
            throw new IllegalArgumentException("파일을 찾을 수 없습니다.");
        } catch (MalformedURLException ex) {
            throw new IllegalStateException("파일을 불러오는 중 오류가 발생했습니다.", ex);
        }
    }

    public QnaAttachment findAttachment(QnaPost post, Long attachmentId) {
        return post.getAttachments().stream()
            .filter(attachment -> attachment.getId().equals(attachmentId))
            .findFirst()
            .orElseThrow(() -> new IllegalArgumentException("첨부파일을 찾을 수 없습니다."));
    }

    private QnaAttachment store(MultipartFile file) {
        try {
            Files.createDirectories(qnaUploadPath);
            String original = StringUtils.cleanPath(file.getOriginalFilename() == null ? "attachment" : file.getOriginalFilename());
            String extension = "";
            int extensionIndex = original.lastIndexOf('.');
            if (extensionIndex >= 0) {
                extension = original.substring(extensionIndex);
            }
            String stored = UUID.randomUUID() + extension;
            file.transferTo(qnaUploadPath.resolve(stored));

            QnaAttachment attachment = new QnaAttachment();
            attachment.setOriginalFilename(original);
            attachment.setStoredFilename(stored);
            attachment.setContentType(file.getContentType());
            attachment.setSize(file.getSize());
            return attachment;
        } catch (IOException ex) {
            throw new IllegalStateException("첨부파일 저장 중 오류가 발생했습니다.", ex);
        }
    }
}
