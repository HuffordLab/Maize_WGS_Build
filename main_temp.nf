#! /usr/bin/env nextflow

nextflow.enable.dsl=2

process get_test_data {
  publishDir './', mode: 'move'

  output:
  path "*"

  script:
  """
  #! /usr/bin/env bash
  wget https://iastate.box.com/shared/static/wt85l6s4nw4kycm2bo0gpgjq752osatu.gz
  tar -xf wt85l6s4nw4kycm2bo0gpgjq752osatu.gz
  """
}

process fasta_sort {
  tag "$fasta"
  publishDir "$params.outdir/sort_fasta"


  input: 
  path fasta

  output: 
  path "${fasta.simpleName}_sorted.fasta"

  script:
  """
  #! /usr/bin/env bash
  cat $fasta |\
    tr '\n' '\t' | sed \$'s/>/\r>/g'| tr '\r' '\n'|\
    sort |\
    tr '\t' '\n' | sed \$'s/\r//g' |\
    grep -v "^\$" > ${fasta.simpleName}_sorted.fasta
  """
}

process fasta_bwa_index {
  tag "$fasta"
  label 'bwa'
  publishDir "${params.outdir}/bwa"
  
  input:
  path fasta

  output:
  path "$fasta", emit: genome_fasta
  path "${fasta}*", emit: genome_index

  script:
  """
  #! /usr/bin/env bash
  bwa index $fasta
  """
}

process fasta_samtools_faidx {
  tag "$fasta"
  label 'samtools'
  publishDir "${params.outdir}/samtools"
  
  input:
  path fasta
  
  output:
  path "${fasta}.fai"

  """
  #! /usr/bin/env bash
  samtools faidx $fasta
  """
}

picard_app='/picard/picard.jar'

process fasta_picard_dict {
  tag "$fasta"
  label 'picard'
  publishDir "${params.outdir}/picard"

  input:
  path fasta

  output:
  path "${fasta.simpleName}.dict"

  script:
  """
  #! /usr/bin/env bash
  java -jar $picard_app CreateSequenceDictionary \
    REFERENCE=${fasta} \
    OUTPUT=${fasta.simpleName}.dict
  """
}

process paired_FastqToSAM {
  tag "$readname"
  label 'picard'
  publishDir "${params.outdir}/picard"

  input:
  tuple val(readname), path(readpairs)

  output:
  path "${readname}.bam"

  """
  #! /usr/bin/env bash
  java -jar $picard_app FastqToSam \
    FASTQ=${readpairs.get(0)} \
    FASTQ2=${readpairs.get(1)} \
    OUTPUT=${readname}.bam \
    READ_GROUP_NAME=${readname} \
    SAMPLE_NAME=${readname}_name \
    LIBRARY_NAME=${readname}_lib \
    PLATFORM="ILLUMINA" \
    SEQUENCING_CENTER="ISU"
  """
}

process BAM_MarkIlluminaAdapters {
  tag "${bam.fileName}"
  label 'picard'
  publishDir "${params.outdir}/picard"

  input:
  path bam

  output:
  path "${bam.simpleName}_marked.bam"  //, emit: bam
  //path "${bam.simpleName}_marked*.txt"

  script:
  """
  #! /usr/bin/env bash
  java -jar $picard_app MarkIlluminaAdapters \
    I=$bam \
    O=${bam.simpleName}_marked.bam \
    M=${bam.simpleName}_marked_metrics.txt
  """
}

process BAM_SamToFastq {
  tag "${bam.fileName}"
  label 'picard'
  publishDir "${params.outdir}/picard"

  input:
  path bam

  output:
  path "${bam.simpleName}_interleaved.fq"

  script:
  """
  #! /usr/bin/env bash
  java -jar $picard_app SamToFastq \
    I=$bam \
    FASTQ=${bam.simpleName}_interleaved.fq \
    CLIPPING_ATTRIBUTE=XT \
    CLIPPING_ACTION=2 \
    INTERLEAVE=true \
    NON_PF=true
  """
}

process run_bwa_mem {
  tag "$readsfq"
  label 'bwa_mem'
  publishDir "${params.outdir}/bwa_mem"

  input:
  tuple path(readsfq), path(genome_fasta), path(genome_index)

  output:
  path "${readsfq.simpleName}_mapped.bam"

  script:
  """
  #! /usr/bin/env bash
  bwa mem \
   -M \
   -t 15 \
   -p ${genome_fasta} \
   ${readsfq} |\
  samtools view -buS - > ${readsfq.simpleName}_mapped.bam
  """
}

process run_MergeBamAlignment {
  tag "$readname"
  label 'picard'
  publishDir "${params.outdir}/picard"

  input:
  tuple val(readname), path(read_unmapped), path(read_mapped), path(genome_fasta), path(genome_index), path(genome_fai), path(genome_dict)

  output:
  tuple path("${readname}_merged.bam"), path("${readname}_merged.bai")

  script:
  """
  #! /usr/bin/env bash
  java -jar $picard_app MergeBamAlignment \
    R=$genome_fasta \
    UNMAPPED_BAM=$read_unmapped \
    ALIGNED_BAM=$read_mapped \
    O=${readname}_merged.bam \
    CREATE_INDEX=true \
    ADD_MATE_CIGAR=true \
    CLIP_ADAPTERS=false \
    CLIP_OVERLAPPING_READS=true \
    INCLUDE_SECONDARY_ALIGNMENTS=true \
    MAX_INSERTIONS_OR_DELETIONS=-1 \
    PRIMARY_ALIGNMENT_STRATEGY=MostDistant \
    ATTRIBUTES_TO_RETAIN=XS
  """
}

workflow prep_genome {
  take: reference_fasta
  main:
    fasta_sort(reference_fasta) | (fasta_bwa_index & fasta_samtools_faidx & fasta_picard_dict )

    genome_ch = fasta_bwa_index.out.genome_fasta
      .combine(fasta_bwa_index.out.genome_index.toList())
      .combine(fasta_samtools_faidx.out)
      .combine(fasta_picard_dict.out)
  
  emit:
    genome_ch
}

workflow prep_reads {
  take: reads_fastas
  main:
    reads_fastas | paired_FastqToSAM | BAM_MarkIlluminaAdapters | BAM_SamToFastq

    reads_ch = BAM_SamToFastq.out
 
  emit:
    reads_ch
}

workflow map_reads {
   take: 
     reads_ch
     genome_ch

   main:
     bwaindex_ch = genome_ch.map { n -> [ n.get(0), n.get(1) ] }
     reads_ch.combine(bwaindex_ch) | run_bwa_mem

     reads_mapped_ch = run_bwa_mem.out.map { n -> [ n.simpleName.replaceFirst("_marked_interleaved_mapped", ""), n ] }
     reads_unmapped_ch = reads_ch.map { n -> [ n.simpleName.replaceFirst("_marked_interleaved",""), n ] }

     reads_merged = reads_unmapped_ch
       .join(reads_mapped_ch)
       .combine(genome_ch)
  
   emit:
     reads_merged
}

workflow {
  main:
    //get_test_data()
    genome_ch = channel.fromPath(params.genome, checkIfExists:true) | prep_genome // | view
    reads_ch = channel.fromFilePairs(params.reads, checkIfExists:true).take(3)| prep_reads //| view
 
    map_reads(reads_ch, genome_ch) | view
  
}