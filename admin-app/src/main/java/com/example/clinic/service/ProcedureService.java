package com.example.clinic.service;

import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.repository.ProcedureProductRepository;
import com.example.clinic.repository.ProcedureSearchRepository;
import java.io.StringReader;
import java.math.BigDecimal;
import java.util.List;
import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;
import org.xml.sax.InputSource;

@Service
public class ProcedureService {

    private final ProcedureProductRepository procedureRepository;
    private final ProcedureSearchRepository procedureSearchRepository;

    public ProcedureService(
        ProcedureProductRepository procedureRepository,
        ProcedureSearchRepository procedureSearchRepository
    ) {
        this.procedureRepository = procedureRepository;
        this.procedureSearchRepository = procedureSearchRepository;
    }

    public List<ProcedureProduct> findActiveProcedures() {
        return procedureRepository.findByActiveTrueOrderByIdAsc();
    }

    public List<ProcedureProduct> findAllProcedures() {
        return procedureRepository.findAllByOrderByIdAsc();
    }

    public List<ProcedureProduct> searchProcedures(String keyword) {
        if (keyword == null || keyword.isBlank()) {
            return findAllProcedures();
        }
        return procedureSearchRepository.searchByName(keyword.trim());
    }

    public ProcedureProduct findById(Long id) {
        return procedureRepository.findById(id)
            .orElseThrow(() -> new IllegalArgumentException("시술 상품을 찾을 수 없습니다."));
    }

    /**
     * 시술/상담 패키지의 가격을 포함한 기본 정보를 수정한다.
     */
    @Transactional
    public ProcedureProduct update(
        Long id,
        String name,
        String category,
        String summary,
        String description,
        BigDecimal price,
        boolean active
    ) {
        ProcedureProduct product = findById(id);
        if (name == null || name.isBlank()) {
            throw new IllegalArgumentException("시술명을 입력해 주세요.");
        }
        if (price == null || price.compareTo(BigDecimal.ZERO) < 0) {
            throw new IllegalArgumentException("가격은 0원 이상이어야 합니다.");
        }
        product.setName(name.trim());
        product.setCategory(category == null ? "" : category.trim());
        product.setSummary(summary == null ? "" : summary.trim());
        product.setDescription(description == null ? "" : description.trim());
        product.setPrice(price);
        product.setActive(active);
        return procedureRepository.save(product);
    }

    @Transactional
    public void delete(Long id) {
        ProcedureProduct product = findById(id);
        product.setActive(false);
        procedureRepository.save(product);
    }

    @Transactional
    public int importFromXml(String xml) throws Exception {
        if (xml == null || xml.isBlank() || xml.length() > 1_048_576
                || xml.toUpperCase(java.util.Locale.ROOT).contains("<!DOCTYPE")) {
            throw new IllegalArgumentException("허용되지 않는 XML 형식입니다.");
        }
        Document document = parseXml(xml);
        if (!"procedures".equals(document.getDocumentElement().getTagName())) {
            throw new IllegalArgumentException("최상위 요소는 procedures여야 합니다.");
        }
        NodeList procedureNodes = document.getElementsByTagName("procedure");
        if (procedureNodes.getLength() == 0 || procedureNodes.getLength() > 100) {
            throw new IllegalArgumentException("한 번에 1~100개 항목만 등록할 수 있습니다.");
        }
        int count = 0;
        for (int i = 0; i < procedureNodes.getLength(); i++) {
            Element element = (Element) procedureNodes.item(i);
            ProcedureProduct product = new ProcedureProduct();
            String name = bounded(text(element, "name"), 100, true);
            String category = bounded(text(element, "category"), 50, false);
            String summary = bounded(text(element, "summary"), 160, false);
            String description = bounded(text(element, "description"), 1000, false);
            BigDecimal price = new BigDecimal(text(element, "price").trim());
            if (price.compareTo(BigDecimal.ZERO) < 0 || price.compareTo(new BigDecimal("100000000")) > 0) {
                throw new IllegalArgumentException("가격 범위를 확인해 주세요.");
            }
            product.setName(name);
            product.setCategory(category);
            product.setSummary(summary);
            product.setDescription(description);
            product.setPrice(price);
            product.setActive(true);
            procedureRepository.save(product);
            count++;
        }
        return count;
    }

    private Document parseXml(String xml) throws Exception {
        // CI-01/SF-08: XXE(외부 엔티티 주입)를 차단하도록 XML 파서를 안전하게 구성한다.
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
        factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
        factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false);
        factory.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
        factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
        factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
        factory.setXIncludeAware(false);
        factory.setExpandEntityReferences(false);
        DocumentBuilder builder = factory.newDocumentBuilder();
        return builder.parse(new InputSource(new StringReader(xml)));
    }

    private String bounded(String value, int maxLength, boolean required) {
        String normalized = value == null ? "" : value.trim();
        if ((required && normalized.isBlank()) || normalized.length() > maxLength) {
            throw new IllegalArgumentException("XML 항목의 길이 또는 필수 값을 확인해 주세요.");
        }
        return normalized;
    }

    private String text(Element parent, String tagName) {
        NodeList nodes = parent.getElementsByTagName(tagName);
        if (nodes.getLength() == 0) {
            return "";
        }
        return nodes.item(0).getTextContent();
    }
}
