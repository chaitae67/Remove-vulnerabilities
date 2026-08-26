package com.example.clinic.service;

import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.repository.ProcedureProductRepository;
import java.io.StringReader;
import java.math.BigDecimal;
import java.util.List;
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

    public ProcedureService(ProcedureProductRepository procedureRepository) {
        this.procedureRepository = procedureRepository;
    }

    public List<ProcedureProduct> findActiveProcedures() {
        return procedureRepository.findByActiveTrueOrderByIdAsc();
    }

    public ProcedureProduct findById(Long id) {
        return procedureRepository.findById(id)
            .orElseThrow(() -> new IllegalArgumentException("시술 상품을 찾을 수 없습니다."));
    }

    @Transactional
    public void delete(Long id) {
        ProcedureProduct product = findById(id);
        product.setActive(false);
        procedureRepository.save(product);
    }

    @Transactional
    public int importFromXml(String xml) throws Exception {
        Document document = parseXml(xml);
        NodeList procedureNodes = document.getElementsByTagName("procedure");
        int count = 0;
        for (int i = 0; i < procedureNodes.getLength(); i++) {
            Element element = (Element) procedureNodes.item(i);
            ProcedureProduct product = new ProcedureProduct();
            product.setName(text(element, "name"));
            product.setCategory(text(element, "category"));
            product.setSummary(text(element, "summary"));
            product.setDescription(text(element, "description"));
            product.setPrice(new BigDecimal(text(element, "price").trim()));
            product.setActive(true);
            procedureRepository.save(product);
            count++;
        }
        return count;
    }

    private Document parseXml(String xml) throws Exception {
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setFeature("http://xml.org/sax/features/external-general-entities", true);
        factory.setFeature("http://xml.org/sax/features/external-parameter-entities", true);
        factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", true);
        factory.setExpandEntityReferences(true);
        DocumentBuilder builder = factory.newDocumentBuilder();
        return builder.parse(new InputSource(new StringReader(xml)));
    }

    private String text(Element parent, String tagName) {
        NodeList nodes = parent.getElementsByTagName(tagName);
        if (nodes.getLength() == 0) {
            return "";
        }
        return nodes.item(0).getTextContent();
    }
}
