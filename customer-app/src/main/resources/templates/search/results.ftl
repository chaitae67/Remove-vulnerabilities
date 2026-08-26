<!DOCTYPE html>
<html lang="ko"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>전체 검색</title><link rel="stylesheet" href="/css/style.css"></head>
<body><#include "/fragments/header.ftl"><main class="global-search-page">
<section class="global-search-hero"><p class="eyebrow">Search Zero Day</p><h1>전체 검색</h1><form class="global-search-form" action="/search" method="get"><input name="keyword" type="search" value="${keyword}" placeholder="찾으시는 내용을 입력하세요" required><button type="submit">검색</button></form><#if keyword?has_content><p><strong>‘${keyword}’</strong> 검색 결과 ${resultCount}건</p><#else><p>프로그램, 공지사항, 이용 후기를 한 번에 검색할 수 있습니다.</p></#if></section>
<section class="global-search-results">
<#if keyword?has_content && resultCount == 0><div class="search-empty"><strong>검색 결과가 없습니다.</strong><p>다른 검색어로 다시 찾아보세요.</p></div></#if>
<#if procedures?size gt 0><div class="search-result-group"><div class="section-head"><h2>프로그램</h2><span>${procedures?size}</span></div><ul><#list procedures as item><li><a href="/procedures"><span class="tag">${item.category}</span><strong>${item.name}</strong><small>${item.summary}</small></a></li></#list></ul></div></#if>
<#if notices?size gt 0><div class="search-result-group"><div class="section-head"><h2>공지사항</h2><span>${notices?size}</span></div><ul><#list notices as item><li><a href="/notices/${item.id}"><strong>${item.title}</strong><small>${temporals.format(item.createdAt, 'yyyy.MM.dd')}</small></a></li></#list></ul></div></#if>
<#if reviews?size gt 0><div class="search-result-group"><div class="section-head"><h2>이용 후기</h2><span>${reviews?size}</span></div><ul><#list reviews as item><li><a href="/reviews/${item.id}"><strong>${item.title}</strong><small>${strings.repeat('★', item.rating)} · ${temporals.format(item.createdAt, 'yyyy.MM.dd')}</small></a></li></#list></ul></div></#if>
</section></main><#include "/fragments/footer.ftl"></body></html>
