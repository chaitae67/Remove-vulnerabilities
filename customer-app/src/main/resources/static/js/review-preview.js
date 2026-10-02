document.addEventListener('DOMContentLoaded', () => {
    const form = document.getElementById('review-form');
    const button = document.getElementById('review-preview-button');
    if (!form || !button) return;
    const photos = document.getElementById('review-photos');
    const section = document.getElementById('review-preview-section');
    const imagePreview = document.getElementById('review-preview-images');
    let objectUrls = [];
    button.addEventListener('click', () => {
        if (!form.reportValidity()) return;
        document.getElementById('review-preview-title').textContent = form.elements.title.value;
        document.getElementById('review-preview-rating').textContent = '★'.repeat(Number(form.elements.rating.value));
        document.getElementById('review-preview-content').textContent = form.elements.content.value;
        objectUrls.forEach(URL.revokeObjectURL);
        objectUrls = [];
        imagePreview.replaceChildren();
        Array.from(photos.files).filter(file => /^image\/(png|jpeg|webp|gif)$/.test(file.type)).forEach(file => {
            const url = URL.createObjectURL(file);
            objectUrls.push(url);
            const image = document.createElement('img');
            image.src = url;
            image.alt = file.name;
            imagePreview.appendChild(image);
        });
        section.hidden = false;
        section.scrollIntoView({behavior: 'smooth', block: 'start'});
    });
});
